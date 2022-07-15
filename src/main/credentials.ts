import fs from 'fs';
import { getAssetPath } from './util';

const CREDENTIALS_FILE = getAssetPath('credentials.json');
const DEFAULT_CREDENTIALS: { [key: string]: { name: string; key: string } } = {
  //  '50:DE:06:78:39:B6': {
  //    name: 'Living Room',
  //    key: '62e3ded54de26431577721c9ffb4280481435e7baf4330fb0635b20564bb2812:f254b8f64a0af3f5437fe4541318b2f3e99e4a634c06f2fe4514febbf5fb2953:46463132383731302d343542332d343846432d423734412d303241344232433133463235:30636663356538632d356264652d343061622d613164662d613334376230383436666237',
  //  },
  //  'F0:B3:EC:65:48:65': {
  //    name: 'Master Bedroom',
  //    key: 'fb2d18cbdab012ca4284f6f14673cfe86616ab48a05734e29bbc4559fba65855:cb19b092668a8d4586b75100844f3fe22f64c3bb667f706ba5d4c4be82a25215:33374135363734422d363143462d343942352d413032332d384242353233303838393439:34353733633166322d636366642d346239652d613531342d396436363964643135636137',
  //  },
};

let credentials: typeof DEFAULT_CREDENTIALS = JSON.parse(
  fs.readFileSync(CREDENTIALS_FILE, 'utf8')
);

export const getCredentials = () => {
  return credentials;
};

export const updateCredentials = (newCreds: typeof DEFAULT_CREDENTIALS) => {
  credentials = newCreds;
  fs.writeFileSync(CREDENTIALS_FILE, JSON.stringify(newCreds), 'utf8');
};
