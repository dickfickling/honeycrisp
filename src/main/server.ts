import axios, { AxiosResponse } from 'axios';
import { ChildProcessWithoutNullStreams, spawn } from 'child_process';
import getPort from 'get-port';
import { getCredentials, updateCredentials } from './credentials';
import { getAssetPath } from './util';

const PYTHON_BINARY = getAssetPath('dist/server');
let port: string;

let spawned: ChildProcessWithoutNullStreams | null = null;

const connect = async (deviceId: string) => {
  const credentials = getCredentials();
  const result = await axios(
    `http://localhost:${port}/connect/${deviceId}?airplay=${credentials[deviceId].key}`
  );
  console.log(result.data);
};

export const start = async () => {
  port = (await getPort()).toString();
  console.log('Starting python on port ', port);
  return new Promise<void>((resolve, reject) => {
    console.log('Starting Python...');
    spawned = spawn(PYTHON_BINARY, [port]);
    spawned.on('error', (error) => {
      console.error('Python spawn error:', error);
      reject(error);
    });
    spawned.stdout.on('data', (chunk) => {
      if (chunk instanceof Buffer) {
        const stringified = chunk.toString();
        process.stdout.write(`Python: ${stringified}`);
        if (stringified.includes('listening')) {
          setTimeout(async () => {
            const credentials = getCredentials();
            await Promise.all(
              Object.keys(credentials).map(async (id) => connect(id))
            );
            resolve();
          }, 200);
        }
      }
    });
  });
};

export const stop = () => {
  spawned?.kill();
  spawned = null;
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

export const control = async (
  deviceId: string,
  command: RemoteCommand,
  autoRetry = true
) => {
  const result: AxiosResponse<{ success: boolean; error: string }> =
    await axios(
      `http://localhost:${port}/remote_control/${deviceId}/${command}`
    );
  if (
    result.data.success === false &&
    result.data.error === 'not_connected' &&
    autoRetry
  ) {
    await connect(deviceId);
    await control(deviceId, command, false);
  }
  console.log({ command, data: result.data, deviceId });
};

export const scan = async (): Promise<Array<{ name: string; id: string }>> => {
  const response = await axios(`http://localhost:${port}/scan`);
  return response.data;
};

export const beginPairing = async (
  deviceId: string
): Promise<{ device_provides_pin: boolean; pin_to_enter?: number }> => {
  const response = await axios(
    `http://localhost:${port}/pair/${deviceId}/begin`
  );
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
  }> = await axios(
    `http://localhost:${port}/pair/${deviceId}/finish?pin=${pin}`
  );
  if (response.data.has_paired && response.data.credentials) {
    const credentials = getCredentials();
    credentials[deviceId] = {
      key: response.data.credentials,
      name: deviceName,
    };
    updateCredentials(credentials);
    await connect(deviceId);
  }
  return response.data;
};

process.on('unhandledRejection', (err) => {
  console.error(err);
  spawned?.kill();
  process.exit();
});
