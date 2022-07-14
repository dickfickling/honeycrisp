import axios, { AxiosResponse } from 'axios';
import { ChildProcessWithoutNullStreams, spawn } from 'child_process';
import { getCredentials, updateCredentials } from './credentials';
import { getAssetPath } from './util';

const PYTHON_BINARY = getAssetPath('dist/server');

let spawned: ChildProcessWithoutNullStreams | null = null;
let ready = false;

export const start = () => {
  console.log('Starting Python...');
  spawned = spawn(PYTHON_BINARY);
  spawned.on('error', (error) => {
    console.error('Python spawn error:', error);
  });
  spawned.stdout.on('data', (chunk) => {
    if (chunk instanceof Buffer) {
      const stringified = chunk.toString();
      process.stdout.write(`Python: ${stringified}`);
      if (stringified.includes('listening')) {
        setTimeout(async () => {
          const credentials = getCredentials();
          await Promise.all(
            Object.entries(credentials).map(async ([id, value]) => {
              await axios(
                `http://localhost:22000/connect/${id}?airplay=${value.key}`
              );
              console.log('Connected to ', id);
            })
          );
          ready = true;
        }, 200);
      }
    }
  });
};

export const stop = () => {
  spawned?.kill();
  spawned = null;
  ready = false;
};

export type RemoteCommand =
  | 'up'
  | 'down'
  | 'left'
  | 'right'
  | 'menu'
  | 'select'
  | 'home_hold'
  | 'volume_up'
  | 'volume_down';

export const control = async (deviceId: string, command: RemoteCommand) => {
  if (ready) {
    await axios(`http://localhost:22000/remote_control/${deviceId}/${command}`);
  }
};

export const scan = async (): Promise<Array<{ name: string; id: string }>> => {
  const response = await axios(`http://localhost:22000/scan`);
  return response.data;
};

export const beginPairing = async (
  deviceId: string
): Promise<{ device_provides_pin: boolean; pin_to_enter?: number }> => {
  const response = await axios(`http://localhost:22000/pair/${deviceId}/begin`);
  return response.data;
};

export const finishPairing = async (
  deviceId: string,
  deviceName: string,
  pin?: number
): Promise<{
  has_paired: boolean;
  credentials?: string;
  error?: string;
}> => {
  const response: AxiosResponse<{
    has_paired: boolean;
    credentials?: string;
    error?: string;
  }> = await axios(`http://localhost:22000/pair/${deviceId}/finish?pin=${pin}`);
  if (response.data.has_paired && response.data.credentials) {
    const credentials = getCredentials();
    credentials[deviceId] = {
      key: response.data.credentials,
      name: deviceName,
    };
    updateCredentials(credentials);
  }
  return response.data;
};

process.on('unhandledRejection', (err) => {
  console.error(err);
  spawned?.kill();
  process.exit();
});
