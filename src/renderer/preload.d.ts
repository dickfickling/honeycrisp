declare global {
  interface Window {
    electron: {
      control: (command: string) => void;
      key: (key: string) => void;
      scan: () => Promise<Array<{ id: string; name: string }>>;
      beginPairing: (
        deviceId: string
      ) => Promise<{ device_provides_pin: boolean; pin_to_enter?: number }>;
      finishPairing: (
        deviceId: string,
        deviceName: string,
        pin?: number
      ) => Promise<{
        has_paired: boolean;
        credentials?: string;
        error?: string;
      }>;
      getCredentials: () => Promise<Record<string, { name: string }>>;
      getActiveDevice: () => Promise<{ id: string; name: string } | null>;
      removeDevice: (name: string) => Promise<void>;
      onActiveDeviceChanged: (cb: (activeDeviceId: string) => void) => void;
    };
  }
}

export {};
