import { contextBridge, ipcRenderer } from 'electron';

export type Channels = 'ipc-example';

contextBridge.exposeInMainWorld('electron', {
  control: (command: string) => ipcRenderer.send('control', command),
  scan: () => ipcRenderer.invoke('scan'),
  beginPairing: (deviceId: string) =>
    ipcRenderer.invoke('beginPairing', deviceId),
  finishPairing: (deviceId: string, deviceName: string, pin?: number) =>
    ipcRenderer.invoke('finishPairing', deviceId, deviceName, pin),
  getCredentials: () => ipcRenderer.invoke('getCredentials'),
  removeDevice: (deviceId: string) =>
    ipcRenderer.invoke('removeDevice', deviceId),
} as Window['electron']);
