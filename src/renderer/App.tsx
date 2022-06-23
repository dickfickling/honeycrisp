import { ButtonHTMLAttributes } from 'react';
import { MemoryRouter as Router, Routes, Route } from 'react-router-dom';
import 'tailwindcss/tailwind.css';

const RoundedButton: React.FC<ButtonHTMLAttributes<HTMLButtonElement>> = (
  props
) => {
  return (
    <button
      type="button"
      {...props}
      className={`rounded-full border border-white m-2 h-20 w-20 text-white ${
        props.className || ''
      }`}
    />
  );
};

const Remote = () => {
  const handlePressButton = (button: string) => {
    window.electron.sendKeypress(button);
  };

  return (
    <div className="bg-black text-white h-screen flex flex-col items-center pt-8">
      <div className="rounded-full border border-white h-40 w-40 flex flex-col items-center justify-between">
        <button
          type="button"
          className="flex-1 w-full"
          onClick={() => handlePressButton('ArrowUp')}
        >
          ^
        </button>
        <div className="flex flex-row flex-1 w-full">
          <button
            type="button"
            className="flex-1"
            onClick={() => handlePressButton('ArrowLeft')}
          >
            {'<'}
          </button>
          <button
            type="button"
            className="flex-1"
            onClick={() => handlePressButton('Enter')}
          >
            o
          </button>
          <button
            type="button"
            className="flex-1"
            onClick={() => handlePressButton('ArrowRight')}
          >
            {'>'}
          </button>
        </div>
        <button
          type="button"
          className="flex-1 w-full"
          onClick={() => handlePressButton('ArrowDown')}
        >
          v
        </button>
      </div>
      <div className="flex flex-row">
        <RoundedButton onClick={() => handlePressButton('Backspace')}>
          Menu
        </RoundedButton>
        <RoundedButton>Home</RoundedButton>
      </div>
      <div className="flex flex-row">
        <div className="flex flex-col">
          <RoundedButton onClick={() => handlePressButton('Enter')}>
            Select
          </RoundedButton>
        </div>
        <div className="flex flex-col border rounded-full border-white m-2">
          <button
            type="button"
            onClick={() => handlePressButton(']')}
            className="text-white h-20 w-20 text-xl"
          >
            +
          </button>
          <button
            type="button"
            onClick={() => handlePressButton('[')}
            className="text-white h-20 w-20 text-xl"
          >
            -
          </button>
        </div>
      </div>
    </div>
  );
};

export default function App() {
  return (
    <Router>
      <Routes>
        <Route path="/" element={<Remote />} />
      </Routes>
    </Router>
  );
}
