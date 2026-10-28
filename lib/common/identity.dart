const _useDevIdentity = bool.fromEnvironment('APP_DEV');

class AppIdentity {
  static const isDev = _useDevIdentity;

  // Internal plumbing name (executables, core, service, data dir). Display brand is displayName.
  static const productName = 'Bettbox';
  static const devSuffix = 'Dev';
  static const packageId = 'app.angelabettbox';

  static const compactName = isDev ? '$productName$devSuffix' : productName;
  static const displayName = isDev ? 'Angela Mihomo Dev' : 'Angela Mihomo';
  static const mainExecutableName = productName;
  static const coreExecutableName = '${compactName}Core';
  static const dataDirName = compactName;
  static const tunDeviceName = compactName;
}

class WindowsHelperIdentity {
  static const serviceName = '${AppIdentity.compactName}HelperService';
  static const pipeName = '\\\\.\\pipe\\${AppIdentity.compactName}.Helper';
}
