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
      className={`rounded-full border border-white m-2 h-20 w-20 text-white ${
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
    <div className="bg-black text-white h-screen flex flex-col items-center pt-8">
      <div className="rounded-full border border-white h-40 w-40 flex flex-col items-center justify-between">
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
        <div className="flex flex-col border rounded-full border-white m-2">
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
  const [devices, setDevices] = useState<Array<{
    name: string;
    id: string;
  }> | null>(null);

  const [pairingDevice, setPairingDevice] = useState<{
    name: string;
    id: string;
  } | null>();
  const [pin, setPin] = useState('');

  useEffect(() => {
    const scan = async () => {
      const results = await window.electron.scan();
      setDevices(results);
    };

    scan();
  }, []);

  const handlePinChange = (evt: React.ChangeEvent<HTMLInputElement>) => {
    setPin(evt.target.value);
  };

  const handlePressPair = async () => {
    const result = await window.electron.finishPairing(
      pairingDevice!.id,
      pairingDevice!.name,
      parseInt(pin, 10)
    );
  };

  return (
    <div className="text-white">
      {devices ? (
        devices.map((d) => {
          const handleDeviceClick = async () => {
            setPairingDevice(d);
            await window.electron.beginPairing(d.id);
          };

          return (
            <div key={d.id}>
              <button type="button" onClick={handleDeviceClick}>
                {d.name}
              </button>
            </div>
          );
        })
      ) : (
        <div>scanning...</div>
      )}
      {pairingDevice ? (
        <div>
          <input
            className="bg-transparent"
            type="text"
            value={pin}
            onChange={handlePinChange}
          />
          <button type="button" onClick={handlePressPair}>
            pair
          </button>
        </div>
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
