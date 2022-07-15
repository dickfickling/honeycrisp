import fs from 'fs';
import { getAssetPath } from './util';

const CREDENTIALS_FILE = getAssetPath('credentials.json');

type Credentials = { [key: string]: { name: string; key: string } };

let credentials: Credentials = JSON.parse(
  fs.readFileSync(CREDENTIALS_FILE, 'utf8')
);

export const getCredentials = () => {
  return credentials;
};

export const updateCredentials = (newCreds: Credentials) => {
  credentials = newCreds;
  fs.writeFileSync(CREDENTIALS_FILE, JSON.stringify(newCreds), 'utf8');
};
