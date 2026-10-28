// Host characterization; the following function is copied byte-for-byte from lib_android.go.
package main
import (
 "core/state"
 "encoding/json"
 _ "github.com/metacubex/mihomo/hub/executor"
 "fmt"
 "sync"
 "os"
 config "github.com/metacubex/mihomo/config"
 log "github.com/metacubex/mihomo/log"
)
var currentConfig *config.Config
var tunLock sync.Mutex
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

func fail(s string) { fmt.Fprintln(os.Stderr,s); os.Exit(1) }
func test(name, spec string) string {
 c,e:=config.Parse([]byte(spec)); if e!=nil { fail(fmt.Sprintf("%s parse: %v",name,e)) }; currentConfig=c
 fmt.Printf("%s parsed include=%q exclude=%q\n",name,c.General.Tun.IncludePackage,c.General.Tun.ExcludePackage)
 result:=handleGetAndroidVpnOptions(); if result=="" {fail("empty projection")}; return result
}
func main(){
 state.CurrentState.VpnProps.Enable=true
 state.CurrentState.VpnProps.AccessControl=&state.AccessControl{Enable:true,Mode:"rejectSelected",RejectList:[]string{"example.denied"}}
 base:=test("baseline","tun:\n  enable: true\n")
 inc:=test("include","tun:\n  enable: true\n  include-package: [example.allowed]\n")
 if len(currentConfig.General.Tun.IncludePackage)!=1 {fail("include not parsed")}
 exc:=test("exclude","tun:\n  enable: true\n  exclude-package: [example.blocked]\n")
 if len(currentConfig.General.Tun.ExcludePackage)!=1 {fail("exclude not parsed")}
 if base==inc || base==exc {fail("projection ignores package fields")}
 var i,e map[string]any
 if err:=json.Unmarshal([]byte(inc), &i); err!=nil {fail(err.Error())}
 if err:=json.Unmarshal([]byte(exc), &e); err!=nil {fail(err.Error())}
 if fmt.Sprint(i["includePackage"])!="[example.allowed]" || fmt.Sprint(e["excludePackage"])!="[example.blocked]" {fail("wrong package projection")}
 fmt.Println("PASS: exact production projection preserves parsed include/exclude arrays; host test, not Android")
}
