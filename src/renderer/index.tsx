import { createRoot } from 'react-dom/client';
import App from './App';

const container = document.getElementById('root')!;
const query = new URLSearchParams(window.location.search);
const root = createRoot(container);
const initialRoute = `/${query.get('initialRoute') || ''}`;
root.render(<App initialRoute={initialRoute} />);

const keyToCommand = {
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Backspace: 'menu',
  h: 'home_hold',
  Enter: 'select',
  ' ': 'select',
  '[': 'volume_down',
  ']': 'volume_up',
};

function isObjKey<T>(key: PropertyKey, obj: T): key is keyof T {
  return key in obj;
}

if (initialRoute === '/') {
  document.addEventListener('keydown', (event) => {
    if (isObjKey(event.key, keyToCommand)) {
      window.electron.control(keyToCommand[event.key]);
    }
  });
}
