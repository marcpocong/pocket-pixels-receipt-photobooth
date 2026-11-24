// Rebuild before ManualCheckoutWebTests; exercises the exact shipped HTML without dependencies.
import {mobileCheckoutPage} from '../src/mobile-checkout.js';
import {mkdirSync,writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const folder=fileURLToPath(new URL('../../../DerivedData/payment-fixtures/',import.meta.url));
mkdirSync(folder,{recursive:true});writeFileSync(folder+'checkout.html',mobileCheckoutPage());
console.log('Manual checkout browser fixture generated from current Worker source.');
