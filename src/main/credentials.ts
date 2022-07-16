import Store from 'electron-store';

type Credentials = { [key: string]: { name: string; key: string } };

const store = new Store<{ credentials: Credentials }>();

export const getCredentials = () => {
  return store.get('credentials', {});
};

export const updateCredentials = (newCreds: Credentials) => {
  store.set('credentials', newCreds);
};
