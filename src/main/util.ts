/* eslint import/prefer-default-export: off, import/no-mutable-exports: off */
import { app } from 'electron';
import { URL } from 'url';
import path from 'path';

const RESOURCES_PATH = app.isPackaged
  ? path.join(process.resourcesPath, 'assets')
  : path.join(__dirname, '../../assets');

export let resolveHtmlPath: (htmlFileName: string, search?: string) => string;

if (process.env.NODE_ENV === 'development') {
  const port = process.env.PORT || 1212;
  resolveHtmlPath = (htmlFileName: string, search?: string) => {
    const url = new URL(`http://localhost:${port}`);
    url.pathname = htmlFileName;
    if (search) {
      url.search = search;
    }
    console.log(url.href);
    return url.href;
  };
} else {
  resolveHtmlPath = (htmlFileName: string, search?: string) => {
    return `file://${path.resolve(
      __dirname,
      '../renderer/',
      `${htmlFileName}${search || ''}`
    )}`;
  };
}

export const getAssetPath = (...paths: string[]): string => {
  return path.join(RESOURCES_PATH, ...paths);
};
