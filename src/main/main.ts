/* eslint global-require: off, no-console: off, promise/always-return: off */

import path from 'path';
import { app, BrowserWindow, ipcMain, Menu, nativeTheme, Tray } from 'electron';
import { resolveHtmlPath, getAssetPath } from './util';
import { start, control, scan, beginPairing, finishPairing } from './server';
import { getCredentials } from './credentials';

let mainWindow: BrowserWindow | null = null;
let activeDeviceId = '50:DE:06:78:39:B6';

ipcMain.on('control', (_event, command) => {
  control(activeDeviceId, command);
});

ipcMain.handle('scan', () => scan());
ipcMain.handle('beginPairing', (_event, deviceId: string) =>
  beginPairing(deviceId)
);
ipcMain.handle(
  'finishPairing',
  (_event, deviceId: string, deviceName: string, pin?: number) =>
    finishPairing(deviceId, deviceName, pin)
);

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
    return getAssetPath('joystick.small.white.png');
  }
  return getAssetPath('joystick.small.png');
};

const createWindow = async () => {
  if (isDebug) {
    await installExtensions();
  }

  const win = new BrowserWindow({
    width: 200,
    height: 500,
    frame: false,
    backgroundColor: 'black',
    icon: getAssetPath('icon.png'),
    webPreferences: {
      preload: app.isPackaged
        ? path.join(__dirname, 'preload.js')
        : path.join(__dirname, '../../.erb/dll/preload.js'),
    },
  });

  win.loadURL(resolveHtmlPath('index.html'));

  return win;
};

const createAddDeviceWindow = async () => {
  if (isDebug) {
    await installExtensions();
  }

  const win = new BrowserWindow({
    width: 500,
    height: 500,
    backgroundColor: 'black',
    icon: getAssetPath('icon.png'),
    webPreferences: {
      preload: app.isPackaged
        ? path.join(__dirname, 'preload.js')
        : path.join(__dirname, '../../.erb/dll/preload.js'),
    },
  });

  win.loadURL(resolveHtmlPath('index.html', '?initialRoute=addDevice'));

  return win;
};

app.on('window-all-closed', (e: Electron.Event) => e.preventDefault());
app.dock.hide();

app
  .whenReady()
  .then(() => {
    const tray = new Tray(getCurrentTrayIcon());
    tray.setToolTip('Click me.');
    start();

    tray.addListener('click', async () => {
      if (mainWindow) {
        mainWindow.close();
      } else {
        mainWindow = await createWindow();
        mainWindow.on('close', () => {
          mainWindow = null;
        });
        // TODO: re-enable this when not developing
        mainWindow.on('blur', mainWindow.close);
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
                    activeDeviceId = id;
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
  })
  .catch(console.log);
