import React, { ButtonHTMLAttributes, useEffect, useState } from 'react';
import { MemoryRouter as Router, Routes, Route } from 'react-router-dom';
import 'tailwindcss/tailwind.css';

const RoundedButton: React.FC<ButtonHTMLAttributes<HTMLButtonElement>> = ({
  className,
  ...rest
}) => {
  return (
    <button
      type="button"
      {...rest}
      className={`rounded-full border m-2 h-20 w-20 text-white ${
        className || ''
      }`}
    />
  );
};

const Remote = () => {
  const handlePressButton = (command: string) => {
    window.electron.control(command);
  };

  return (
    <div className="bg-darkGray text-white h-screen flex flex-col items-center pt-8">
      <div className="rounded-full border h-40 w-40 flex flex-col items-center justify-between">
        <button
          type="button"
          className="flex-1 w-full"
          onClick={() => handlePressButton('up')}
        >
          ^
        </button>
        <div className="flex flex-row flex-1 w-full">
          <button
            type="button"
            className="flex-1"
            onClick={() => handlePressButton('left')}
          >
            {'<'}
          </button>
          <button
            type="button"
            className="flex-1"
            onClick={() => handlePressButton('select')}
          >
            o
          </button>
          <button
            type="button"
            className="flex-1"
            onClick={() => handlePressButton('right')}
          >
            {'>'}
          </button>
        </div>
        <button
          type="button"
          className="flex-1 w-full"
          onClick={() => handlePressButton('down')}
        >
          v
        </button>
      </div>
      <div className="flex flex-row">
        <RoundedButton onClick={() => handlePressButton('menu')}>
          Menu
        </RoundedButton>
        <RoundedButton onClick={() => handlePressButton('home_hold')}>
          Home
        </RoundedButton>
      </div>
      <div className="flex flex-row">
        <div className="flex flex-col">
          <RoundedButton onClick={() => handlePressButton('select')}>
            Select
          </RoundedButton>
        </div>
        <div className="flex flex-col border rounded-full m-2">
          <button
            type="button"
            onClick={() => handlePressButton('volume_up')}
            className="text-white h-20 w-20 text-xl"
          >
            +
          </button>
          <button
            type="button"
            onClick={() => handlePressButton('volume_down')}
            className="text-white h-20 w-20 text-xl"
          >
            -
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

  const handlePressPair = async () => {
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
          <input
            className="bg-transparent outline-none px-4"
            placeholder="Enter the PIN on your TV"
            type="text"
            value={pin}
            onChange={handlePinChange}
          />
          <button
            className="rounded-full border py-2 px-4"
            type="button"
            onClick={handlePressPair}
          >
            Pair
          </button>
        </div>
      ) : null}
      {paired ? (
        <div className="text-xl mt-8">Paired! Please close this window.</div>
      ) : null}
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
      </Routes>
    </Router>
  );
};

export default App;
