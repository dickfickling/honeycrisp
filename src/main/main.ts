/* eslint global-require: off, no-console: off, promise/always-return: off */

/**
 * This module executes inside of electron's main process. You can start
 * electron renderer process from here and communicate with the other processes
 * through IPC.
 *
 * When running `npm run build` or `npm run build:main`, this file is compiled to
 * `./src/main.js` using webpack. This gives us some performance wins.
 */
import path from 'path';
import { app, BrowserWindow, ipcMain, Menu, nativeTheme, Tray } from 'electron';
import { resolveHtmlPath } from './util';
import { start, stop, keyPressed, DeviceName } from './server';
import { getAssetPath } from './utils';

let mainWindow: BrowserWindow | null = null;
let activeDevice: DeviceName = 'livingRoom';

ipcMain.on('ipc-example', async (event, arg) => {
  const msgTemplate = (pingPong: string) => `IPC test: ${pingPong}`;
  console.log(msgTemplate(arg));
  event.reply('ipc-example', msgTemplate('pong'));
});

ipcMain.on('keyPress', (_event, key) => {
  keyPressed(activeDevice, key);
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

app.on('window-all-closed', (e: Electron.Event) => e.preventDefault());
app.dock.hide();

app
  .whenReady()
  .then(() => {
    const tray = new Tray(getCurrentTrayIcon());
    tray.setToolTip('Click me.');

    tray.addListener('click', async () => {
      if (mainWindow) {
        mainWindow.close();
      } else {
        start();
        mainWindow = await createWindow();
        mainWindow.on('close', () => {
          stop();
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
      tray.popUpContextMenu(
        Menu.buildFromTemplate([
          {
            label: 'Device',
            submenu: [
              {
                label: 'Living Room',
                type: 'radio',
                checked: activeDevice === 'livingRoom',
                click() {
                  activeDevice = 'livingRoom';
                },
              },
              {
                label: 'Bedroom',
                type: 'radio',
                checked: activeDevice === 'bedroom',
                click() {
                  activeDevice = 'bedroom';
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
