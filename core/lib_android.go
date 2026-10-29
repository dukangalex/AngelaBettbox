//go:build android && cgo

package main

import "C"
import (
	"context"
	bridge "core/dart-bridge"
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sync/semaphore"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer
	limit    *semaphore.Weighted
}

func (t *TunHandler) close() {
	_ = t.limit.Acquire(context.TODO(), 4)
	defer t.limit.Release(4)
	removeTunHook()
	if t.listener != nil {
		_ = t.listener.Close()
	}

	if t.callback != nil {
		releaseObject(t.callback)
	}
	t.callback = nil
	t.listener = nil
}

func (t *TunHandler) handleProtect(fd int) bool {
	if err := t.limit.Acquire(context.Background(), 1); err != nil {
		return false
	}
	defer t.limit.Release(1)

	cb := t.callback
	return cb != nil && Protect(cb, fd)
}

func (t *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	if t.listener == nil {
		return ""
	}
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return ResolveProcess(t.callback, protocol, source.String(), target.String(), uid)
}

var (
	tunLock          sync.Mutex // serializes listener construction and teardown
	runTime          *time.Time // accessed under tunLock
	errBlocked       = errors.New("blocked")
	errTunTransition = errors.New("tun lifecycle is transitioning")
	errTunProtect    = errors.New("vpn socket protection failed")
	tunHandler       atomic.Pointer[TunHandler]
	tunLifecycle     tunLifecycleState
)

func init() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		var gateOpen bool
		protected := false
		if err := conn.Control(func(fd uintptr) {
			gateOpen = tunLifecycle.withRunning(func() bool {
				handler := tunHandler.Load()
				if handler == nil {
					protected = true // non-VPN core run (fd == 0)
					return true
				}
				protected = handler.handleProtect(int(fd))
				return true
			})
		}); err != nil {
			return err
		}
		if !gateOpen {
			return errTunTransition
		}
		if !protected {
			return errTunProtect
		}
		return nil
	}
}

// closeTunHandlerLocked tears down only the currently published handler. The
// caller holds tunLock, which serializes start/stop and listener ownership.
func closeTunHandlerLocked() {
	runTime = nil
	handler := tunHandler.Swap(nil)
	if handler != nil {
		handler.close()
	} else {
		removeTunHook()
	}
}

func closeUnclaimedTunFD(fd int) {
	if fd <= 0 {
		return
	}
	if err := syscall.Close(fd); err != nil {
		log.Warnln("[APP] close unclaimed TUN descriptor %d failed: %v", fd, err)
	}
}

func startTunLocked(fd int, callback unsafe.Pointer) error {
	fdUnclaimed := fd > 0
	defer func() {
		if fdUnclaimed {
			closeUnclaimedTunFD(fd)
		}
	}()
	closeTunHandlerLocked()
	if fd == 0 {
		if callback != nil {
			releaseObject(callback)
		}
		now := time.Now()
		runTime = &now
		return nil
	}
	if callback == nil {
		return errors.New("VPN protect callback is unavailable")
	}
	if currentConfig == nil {
		log.Warnln("[APP] startTUN called before setupConfig")
		releaseObject(callback)
		return errors.New("core configuration is unavailable")
	}
	handler := &TunHandler{callback: callback, limit: semaphore.NewWeighted(4)}
	tunHandler.Store(handler)
	initTunHook()
	// Ownership moves to core/tun.Start, which either closes the descriptor on
	// validation failure or passes it to sing_tun.New for listener ownership.
	fdUnclaimed = false
	listener, err := t.Start(fd, currentConfig.General.Tun.Device, currentConfig.General.Tun.Stack, currentConfig.General.Tun.DNSMode, currentConfig.General.Tun.DisableICMPForwarding, uint32(currentConfig.General.Tun.MTU), currentConfig.General.IPv6, currentConfig.General.Tun.CongestionController, currentBlockTunUDP)
	if err != nil {
		if tunHandler.CompareAndSwap(handler, nil) {
			removeTunHook()
		}
		handler.close()
		return fmt.Errorf("start TUN listener: %w", err)
	}
	if listener == nil {
		if tunHandler.CompareAndSwap(handler, nil) {
			removeTunHook()
		}
		handler.close()
		return errors.New("start TUN listener returned no listener")
	}
	handler.listener = listener
	log.Infoln("TUN address: %v", listener.Address())
	now := time.Now()
	runTime = &now
	return nil
}

func beginTunTransitionState() uint64 {
	return tunLifecycle.begin()
}

func stopTunEpochState(epoch uint64) bool {
	if !tunLifecycle.stop(epoch) {
		return false
	}
	tunLock.Lock()
	defer tunLock.Unlock()
	// A newer transition can supersede this stop while it waits for an in-flight
	// Start. Never let a late stop close that newer epoch's listener.
	if !tunLifecycle.current(epoch) {
		return false
	}
	closeTunHandlerLocked()
	return true
}

func handleStopTun() {
	epoch := beginTunTransitionState()
	_ = stopTunEpochState(epoch)
}

func handleGetRunTime() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	if runTime == nil {
		return ""
	}
	return strconv.FormatInt(runTime.UnixMilli(), 10)
}

func initTunHook() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		handler := tunHandler.Load()
		if handler == nil {
			return "", errors.New("tun is closed")
		}
		return handler.handleResolveProcess(src, dst), nil
	}
}

func removeTunHook() {
	process.DefaultPackageNameResolver = nil
}

func handleGetAndroidVpnOptions() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	if currentConfig == nil {
		log.Warnln("[APP] handleGetAndroidVpnOptions called before setupConfig")
		return ""
	}
	ipv6Address := ""
	if currentConfig.General.IPv6 {
		ipv6Address = state.DefaultIpv6Address
	}
	options := state.AndroidVpnOptions{
		Enable:                state.CurrentState.VpnProps.Enable,
		Port:                  currentConfig.General.MixedPort,
		Ipv4Address:           state.DefaultIpv4Address,
		Ipv6Address:           ipv6Address,
		AccessControl:         state.CurrentState.VpnProps.AccessControl,
		SystemProxy:           state.CurrentState.VpnProps.SystemProxy,
		AllowBypass:           state.CurrentState.VpnProps.AllowBypass,
		RouteAddress:          currentConfig.General.Tun.RouteAddress,
		IncludePackage:        currentConfig.General.Tun.IncludePackage,
		ExcludePackage:        currentConfig.General.Tun.ExcludePackage,
		RouteMode:             state.CurrentState.VpnProps.RouteMode,
		BypassDomain:          state.CurrentState.BypassDomain,
		DnsServerAddress:      state.GetDnsServerAddress(),
		DozeSuspend:           state.CurrentState.VpnProps.DozeSuspend,
		DisableIcmpForwarding: currentConfig.General.Tun.DisableICMPForwarding,
		Mtu:                   uint32(currentConfig.General.Tun.MTU),
	}
	data, err := json.Marshal(options)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleUpdateDns(value string) {
	go func() {
		log.Infoln("[DNS] updateDns %s", value)
		dns.UpdateSystemDNS(strings.Split(value, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
}

func handleGetCurrentProfileName() string {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func nextHandle(action *Action, result ActionResult) bool {
	switch action.Method {
	case getAndroidVpnOptionsMethod:
		result.success(handleGetAndroidVpnOptions())
		return true
	case updateDnsMethod:
		data := action.Data.(string)
		handleUpdateDns(data)
		result.success(true)
		return true
	case getRunTimeMethod:
		result.success(handleGetRunTime())
		return true
	case getCurrentProfileNameMethod:
		result.success(handleGetCurrentProfileName())
		return true
	}
	return false
}

//export quickStart
func quickStart(initParamsChar *C.char, paramsChar *C.char, stateParamsChar *C.char, port C.longlong) {
	i := int64(port)
	paramsString := C.GoString(initParamsChar)
	bytes := []byte(C.GoString(paramsChar))
	stateParams := C.GoString(stateParamsChar)
	go func() {
		res := handleInitClash(paramsString)
		if res == false {
			bridge.SendToPort(i, "init error")
			return
		}
		handleSetState(stateParams)
		result, _ := json.Marshal(handleSetupConfig(bytes))
		bridge.SendToPort(i, string(result))
	}()
}

//export startTUN
func startTUN(fd C.int, callback unsafe.Pointer, epoch C.longlong) bool {
	tunLock.Lock()
	defer tunLock.Unlock()
	if !tunLifecycle.canStart(uint64(epoch)) {
		closeUnclaimedTunFD(int(fd))
		if callback != nil {
			releaseObject(callback)
		}
		return false
	}
	if err := startTunLocked(int(fd), callback); err != nil {
		log.Errorln("[APP] TUN start failed: %v", err)
		return false
	}
	if !tunLifecycle.activate(uint64(epoch)) {
		closeTunHandlerLocked()
		return false
	}
	return true
}

//export beginTunTransition
func beginTunTransition() C.longlong {
	return C.longlong(beginTunTransitionState())
}

//export stopTunEpoch
func stopTunEpoch(epoch C.longlong) bool {
	return stopTunEpochState(uint64(epoch))
}

//export getRunTime
func getRunTime() *C.char {
	return C.CString(handleGetRunTime())
}

//export stopTun
func stopTun() {
	handleStopTun()
}

//export getCurrentProfileName
func getCurrentProfileName() *C.char {
	return C.CString(handleGetCurrentProfileName())
}

//export getAndroidVpnOptions
func getAndroidVpnOptions() *C.char {
	return C.CString(handleGetAndroidVpnOptions())
}

//export setState
func setState(s *C.char) {
	paramsString := C.GoString(s)
	handleSetState(paramsString)
}

//export updateDns
func updateDns(s *C.char) {
	dnsList := C.GoString(s)
	handleUpdateDns(dnsList)
}
