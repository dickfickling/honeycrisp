import React, { ButtonHTMLAttributes, useEffect, useState } from 'react';
import { MemoryRouter as Router, Routes, Route } from 'react-router-dom';
import 'tailwindcss/tailwind.css';
import './css/all.css';

const RoundedButton: React.FC<ButtonHTMLAttributes<HTMLButtonElement>> = ({
  className,
  ...rest
}) => {
  return (
    <button
      type="button"
      {...rest}
      className={`bg-gray-900 rounded-full m-2 h-20 w-20 text-white ${
        className || ''
      }`}
    />
  );
};

const Dot = () => <div className="h-1 w-1 rounded-full bg-white" />;

const Remote = () => {
  const handleRemoteButton = (command: string) => {
    window.electron.control(command);
  };

  return (
    <div
      className="bg-gray-400 text-white h-screen flex flex-col items-center"
      // eslint-disable-next-line @typescript-eslint/ban-ts-comment
      // @ts-ignore
      style={{ webkitAppRegion: 'drag' }}
    >
      <button
        type="button"
        className="rounded-full border border-gray-900 text-gray-900 h-8 w-8 self-end mt-4 mr-4"
        onClick={() => handleRemoteButton('power_toggle')}
      >
        <i className="far fa-power-off" />
      </button>
      <div className="rounded-full overflow-hidden bg-gray-900 h-40 w-40 grid grid-cols-4 grid-rows-4 mt-2">
        <button
          type="button"
          className="col-span-4 flex pt-2 justify-center"
          onClick={() => handleRemoteButton('up')}
        >
          <Dot />
        </button>
        <div className="col-span-4 row-span-2 grid grid-cols-4">
          <button
            type="button"
            className="flex items-center pl-2"
            onClick={() => handleRemoteButton('left')}
          >
            <Dot />
          </button>
          <button
            type="button"
            className="col-span-2 rounded-full border border-gray-600"
            onClick={() => handleRemoteButton('select')}
          >
            {' '}
          </button>
          <button
            type="button"
            className="flex justify-end items-center pr-2"
            onClick={() => handleRemoteButton('right')}
          >
            <Dot />
          </button>
        </div>
        <button
          type="button"
          className="col-span-4 flex justify-center items-end pb-2"
          onClick={() => handleRemoteButton('down')}
        >
          <Dot />
        </button>
      </div>
      <div className="flex flex-row">
        <RoundedButton onClick={() => handleRemoteButton('menu')}>
          <i className="fal fa-chevron-left text-2xl" />
        </RoundedButton>
        <RoundedButton onClick={() => handleRemoteButton('home_hold')}>
          <i className="fal fa-tv" />
        </RoundedButton>
      </div>
      <div className="flex flex-row">
        <div className="flex flex-col">
          <RoundedButton onClick={() => handleRemoteButton('play_pause')}>
            <i className="fal fa-play text-lg" />{' '}
            <i className="fal fa-pause text-lg" />
          </RoundedButton>
        </div>
        <div className="flex flex-col bg-gray-900 rounded-full m-2">
          <button
            type="button"
            onClick={() => handleRemoteButton('volume_up')}
            className="text-white h-20 w-20"
          >
            <i className="fal fa-plus text-xl" />
          </button>
          <button
            type="button"
            onClick={() => handleRemoteButton('volume_down')}
            className="text-white h-20 w-20"
          >
            <i className="fal fa-minus text-xl" />
          </button>
        </div>
      </div>
    </div>
  );
};

const AddDevice = () => {
  // TODO: default to null
  const [devices, setDevices] = useState<Array<{
    name: string;
    id: string;
  }> | null>(null);

  const [pairingDevice, setPairingDevice] = useState<{
    name: string;
    id: string;
  } | null>();
  const [pin, setPin] = useState('');
  const [pairing, setPairing] = useState(false);
  const [paired, setPaired] = useState(false);

  useEffect(() => {
    const scan = async () => {
      const results = await window.electron.scan();
      setDevices(results);
    };

    scan();
  }, []);

  const handlePinChange = (evt: React.ChangeEvent<HTMLInputElement>) => {
    setPin(evt.target.value.replace(/\D+/g, '').substring(0, 4));
  };

  const handlePinSubmit = async (evt: React.FormEvent) => {
    evt.preventDefault();
    await window.electron.finishPairing(
      pairingDevice!.id,
      pairingDevice!.name,
      parseInt(pin, 10)
    );
    setPairing(false);
    setPaired(true);
  };

  const handleSelectChange = (evt: React.ChangeEvent<HTMLSelectElement>) => {
    const id = evt.target.value;
    const device = devices?.find((d) => d.id === id);
    setPairingDevice(device);
  };

  const handleClickBegin = async () => {
    setPairing(true);
    await window.electron.beginPairing(pairingDevice!.id);
  };

  return (
    <div className="text-white bg-darkGray p-4 text-center">
      <h1 className="text-lg">Connect a new device</h1>
      {devices ? (
        <>
          <div className="inline-block border mt-4">
            <select
              className="bg-transparent m-2 outline-none"
              defaultValue={devices[0].id}
              onChange={handleSelectChange}
            >
              {devices.map((d) => {
                return (
                  <option key={d.id} value={d.id}>
                    {d.name}
                  </option>
                );
              })}
            </select>
          </div>
          <div>
            <button
              className="border px-8 py-2 rounded-full mt-4"
              onClick={handleClickBegin}
              type="button"
            >
              Start
            </button>
          </div>
        </>
      ) : (
        <div>scanning...</div>
      )}
      {pairing ? (
        <div className="inline-block rounded-full border mt-4">
          <form onSubmit={handlePinSubmit}>
            <input
              className="bg-transparent outline-none px-4"
              placeholder="Enter the PIN on your TV"
              type="text"
              value={pin}
              onChange={handlePinChange}
            />
            <button className="rounded-full border py-2 px-4" type="submit">
              Pair
            </button>
          </form>
        </div>
      ) : null}
      {paired ? (
        <div className="text-xl mt-8">Paired! Please close this window.</div>
      ) : null}
    </div>
  );
};

const ManageDevices = () => {
  const [devices, setDevices] = useState<Array<{
    deviceId: string;
    name: string;
  }> | null>(null);

  useEffect(() => {
    const loadDevices = async () => {
      const results = await window.electron.getCredentials();
      setDevices(
        Object.entries(results).map(([deviceId, value]) => ({
          deviceId,
          name: value.name,
        }))
      );
    };

    loadDevices();
  }, []);

  const removeDevice = (deviceId: string) => {
    window.electron.removeDevice(deviceId);
    setDevices(devices?.filter((d) => d.deviceId !== deviceId) ?? null);
  };

  return (
    <div className="text-white">
      <h1 className="text-center mt-2 mb-3">Manage Devices</h1>
      <div className="flex flex-col">
        {devices?.map(({ deviceId, name }) => {
          return (
            <div key={deviceId} className="flex flex-row items-center">
              <button type="button" onClick={() => removeDevice(deviceId)}>
                <i className="far fa-trash-alt text-lg p-2" />
              </button>
              <h2>{name}</h2>
            </div>
          );
        })}
      </div>
    </div>
  );
};

type AppProps = { initialRoute: string };
const App: React.FC<AppProps> = ({ initialRoute }) => {
  return (
    <Router initialEntries={[initialRoute]}>
      <Routes>
        <Route path="/" element={<Remote />} />
        <Route path="/addDevice" element={<AddDevice />} />
        <Route path="/manageDevices" element={<ManageDevices />} />
      </Routes>
    </Router>
  );
};

export default App;
