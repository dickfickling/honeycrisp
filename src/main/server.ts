import axios from 'axios';
import { ChildProcessWithoutNullStreams, spawn } from 'child_process';
import { getAssetPath } from './utils';

export type DeviceName = keyof typeof config;

const config = {
  livingRoom: {
    id: '50DE067839B6',
    key: '62e3ded54de26431577721c9ffb4280481435e7baf4330fb0635b20564bb2812:f254b8f64a0af3f5437fe4541318b2f3e99e4a634c06f2fe4514febbf5fb2953:46463132383731302d343542332d343846432d423734412d303241344232433133463235:30636663356538632d356264652d343061622d613164662d613334376230383436666237',
  },
  bedroom: {
    id: 'F0B3EC654865',
    key: 'fb2d18cbdab012ca4284f6f14673cfe86616ab48a05734e29bbc4559fba65855:cb19b092668a8d4586b75100844f3fe22f64c3bb667f706ba5d4c4be82a25215:33374135363734422d363143462d343942352d413032332d384242353233303838393439:34353733633166322d636366642d346239652d613531342d396436363964643135636137',
  },
};

let spawned: ChildProcessWithoutNullStreams | null = null;

const PYTHON_BINARY = getAssetPath('dist/server');

export const start = () => {
  console.log('Starting...');
  spawned = spawn(PYTHON_BINARY);
  console.log('Spawned');
  spawned.stderr.on('data', (chunk) => {
    if (chunk instanceof Buffer) {
      const stringified = chunk.toString();
      process.stdout.write(`Error: ${stringified}`);
    }
  });
  spawned.on('error', (error) => {
    console.log('spawn error:', error);
  });
  spawned.stdout.on('data', (chunk) => {
    if (chunk instanceof Buffer) {
      const stringified = chunk.toString();
      process.stdout.write(`Python: ${stringified}`);
      if (stringified.includes('listening')) {
        setTimeout(async () => {
          await axios(
            `http://localhost:22000/connect/${config.bedroom.id}?airplay=${config.bedroom.key}`
          );
          await axios(
            `http://localhost:22000/connect/${config.livingRoom.id}?airplay=${config.livingRoom.key}`
          );
        }, 200);
      }
    }
  });
};

export const stop = () => {
  spawned?.kill();
  spawned = null;
};

export const keyPressed = async (device: DeviceName, key: string) => {
  const baseUrl = `http://localhost:22000/remote_control/${config[device].id}`;
  if (key === 'ArrowUp') {
    await axios(`${baseUrl}/up`);
  } else if (key === 'ArrowDown') {
    await axios(`${baseUrl}/down`);
  } else if (key === 'ArrowLeft') {
    await axios(`${baseUrl}/left`);
  } else if (key === 'ArrowRight') {
    await axios(`${baseUrl}/right`);
  } else if (key === 'Backspace') {
    await axios(`${baseUrl}/menu`);
  } else if (key === ' ' || key === 'Enter') {
    await axios(`${baseUrl}/select`);
  } else if (key === 'h') {
    await axios(`${baseUrl}/home_hold`);
  } else if (key === '[') {
    await axios(`${baseUrl}/volume_down`);
  } else if (key === ']') {
    await axios(`${baseUrl}/volume_up`);
  }
};

process.on('unhandledRejection', (err) => {
  console.error(err);
  spawned?.kill();
  process.exit();
});
