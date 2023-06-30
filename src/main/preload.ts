import { contextBridge, ipcRenderer } from 'electron';

export type Channels = 'ipc-example';

contextBridge.exposeInMainWorld('electron', {
  control: (command: string) => ipcRenderer.send('control', command),
  scan: () => ipcRenderer.invoke('scan'),
  key: (key: string) => ipcRenderer.send('key', key),
  beginPairing: (deviceId: string) =>
    ipcRenderer.invoke('beginPairing', deviceId),
  finishPairing: (deviceId: string, deviceName: string, pin?: number) =>
    ipcRenderer.invoke('finishPairing', deviceId, deviceName, pin),
  getCredentials: () => ipcRenderer.invoke('getCredentials'),
  getActiveDevice: () => ipcRenderer.invoke('getActiveDevice'),
  removeDevice: (deviceId: string) =>
    ipcRenderer.invoke('removeDevice', deviceId),
  onActiveDeviceChanged: (cb: (activeDeviceId: string) => void) =>
    ipcRenderer.on('active-device-changed', (_evt, value) => cb(value)),
} as Window['electron']);
