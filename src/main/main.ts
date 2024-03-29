/* eslint global-require: off, no-console: off, promise/always-return: off */

import path from 'path';
import { app, BrowserWindow, ipcMain, Menu, nativeTheme, Tray } from 'electron';
import { resolveHtmlPath, getAssetPath } from './util';
import {
  start,
  control,
  scan,
  beginPairing,
  finishPairing,
  stop,
} from './server';
import { getCredentials, updateCredentials } from './credentials';

let mainWindow: BrowserWindow | null = null;
let activeDeviceId = Object.keys(getCredentials())[0];
let bounds: Electron.Rectangle | null = null;

ipcMain.on('control', (_event, command) => {
  control(activeDeviceId, command);
});

ipcMain.on('key', (_event, key) => {
  console.log('key', key);
});

ipcMain.handle('scan', () => scan());
ipcMain.handle('beginPairing', (_event, deviceId: string) =>
  beginPairing(deviceId)
);
ipcMain.handle(
  'finishPairing',
  async (_event, deviceId: string, deviceName: string, pin?: number) => {
    await finishPairing(deviceId, deviceName, pin);
    setActiveDevice(deviceId);
  }
);
ipcMain.handle('getActiveDevice', () => {
  const credentials = getCredentials();
  if (activeDeviceId && credentials[activeDeviceId]) {
    return { id: activeDeviceId, name: credentials[activeDeviceId].name };
  }
  return null;
});
ipcMain.handle('getCredentials', () => getCredentials());
ipcMain.handle('removeDevice', (_event, deviceId: string) => {
  const credentials = getCredentials();
  delete credentials[deviceId];
  updateCredentials(credentials);
  return credentials;
});

if (process.env.NODE_ENV === 'production') {
  const sourceMapSupport = require('source-map-support');
  sourceMapSupport.install();
}

const isDebug =
  process.env.NODE_ENV === 'development' || process.env.DEBUG_PROD === 'true';

if (isDebug) {
  // enable this to show the inspector
  // require('electron-debug')();
}

const setActiveDevice = (deviceId: string) => {
  activeDeviceId = deviceId;
  mainWindow?.webContents.send('active-device-changed', deviceId);
};

const installExtensions = async () => {
  const installer = require('electron-devtools-installer');
  const forceDownload = !!process.env.UPGRADE_EXTENSIONS;
  const extensions = ['REACT_DEVELOPER_TOOLS'];

  return installer
    .default(
      extensions.map((name) => installer[name]),
      forceDownload
    )
    .catch(console.log);
};

const getCurrentTrayIcon = () => {
  if (nativeTheme.shouldUseDarkColors) {
    return getAssetPath('remote.dark.png');
  }
  return getAssetPath('remote.light.png');
};

const createWindow = async () => {
  if (isDebug) {
    await installExtensions();
  }

  mainWindow = new BrowserWindow({
    width: bounds?.width || 200,
    height: bounds?.height || 500,
    x: bounds?.x,
    y: bounds?.y,
    frame: false,
    backgroundColor: 'rgb(156,163,175)',
    icon: getAssetPath('remote.light.png'),
    webPreferences: {
      preload: app.isPackaged
        ? path.join(__dirname, 'preload.js')
        : path.join(__dirname, '../../.erb/dll/preload.js'),
    },
  });

  mainWindow.loadURL(resolveHtmlPath('index.html'));

  mainWindow.on('close', () => {
    bounds = mainWindow!.getBounds();
    mainWindow = null;
  });
};

const createAddDeviceWindow = async () => {
  if (isDebug) {
    await installExtensions();
  }

  const win = new BrowserWindow({
    width: 400,
    height: 400,
    backgroundColor: '#101012',
    icon: getAssetPath('remote.light.png'),
    webPreferences: {
      preload: app.isPackaged
        ? path.join(__dirname, 'preload.js')
        : path.join(__dirname, '../../.erb/dll/preload.js'),
    },
  });

  win.loadURL(resolveHtmlPath('index.html', '?initialRoute=addDevice'));
};

const createManageDevicesWindow = async () => {
  if (isDebug) {
    await installExtensions();
  }

  const win = new BrowserWindow({
    width: 200,
    height: 400,
    backgroundColor: '#101012',
    icon: getAssetPath('remote.light.png'),
    webPreferences: {
      preload: app.isPackaged
        ? path.join(__dirname, 'preload.js')
        : path.join(__dirname, '../../.erb/dll/preload.js'),
    },
  });

  win.loadURL(resolveHtmlPath('index.html', '?initialRoute=manageDevices'));
};

app.on('window-all-closed', (e: Electron.Event) => e.preventDefault());
app.on('will-quit', () => stop());

app
  .whenReady()
  .then(async () => {
    await start();
    const tray = new Tray(getCurrentTrayIcon());
    tray.setToolTip('Click me.');

    tray.addListener('click', () => {
      if (!activeDeviceId) {
        createAddDeviceWindow();
      } else if (mainWindow) {
        mainWindow.show();
      } else {
        createWindow();
      }
    });

    nativeTheme.on('updated', () => {
      tray.setImage(getCurrentTrayIcon());
    });

    tray.on('right-click', () => {
      const credentials = getCredentials();
      tray.popUpContextMenu(
        Menu.buildFromTemplate([
          {
            label: 'Device',
            submenu: [
              ...Object.entries(credentials).map(([id, value]) => {
                return {
                  label: value.name,
                  type: 'radio',
                  checked: activeDeviceId === id,
                  click() {
                    setActiveDevice(id);
                  },
                } as const;
              }),
              {
                type: 'separator',
              },
              {
                label: 'Add Device',
                click() {
                  createAddDeviceWindow();
                },
              },
              {
                label: 'Manage Devices',
                click() {
                  createManageDevicesWindow();
                },
              },
            ],
          },
          {
            label: 'Quit',
            click() {
              app.quit();
            },
          },
        ])
      );
    });

    if (activeDeviceId) {
      createWindow();
    } else {
      createAddDeviceWindow();
    }
  })
  .catch(console.log);
