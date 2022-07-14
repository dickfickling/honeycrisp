import { contextBridge, ipcRenderer } from 'electron';

export type Channels = 'ipc-example';

contextBridge.exposeInMainWorld('electron', {
  control: (command: string) => ipcRenderer.send('control', command),
  scan: () => ipcRenderer.invoke('scan'),
  beginPairing: (deviceId: string) =>
    ipcRenderer.invoke('beginPairing', deviceId),
  finishPairing: (deviceId: string, deviceName: string, pin?: number) =>
    ipcRenderer.invoke('finishPairing', deviceId, deviceName, pin),
} as Window['electron']);
