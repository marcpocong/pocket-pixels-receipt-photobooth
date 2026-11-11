const fs=require('fs'),vm=require('vm'),path=require('path'),cp=require('child_process');
const out=process.argv[2];fs.mkdirSync(out,{recursive:true});
let seed=42;const ppm=Buffer.alloc(960*720*3);for(let i=0;i<ppm.length;i++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;ppm[i]=seed>>>24;}
fs.writeFileSync(out+'/photo.ppm',Buffer.concat([Buffer.from('P6\n960 720\n255\n'),ppm]));cp.execFileSync('sips',['-s','format','jpeg','-s','formatOptions','45',out+'/photo.ppm','--out',out+'/photo.jpg'],{stdio:'ignore'});
cp.execFileSync('sips',['-z','1000','384','-s','format','jpeg','-s','formatOptions','45',out+'/photo.ppm','--out',out+'/receipt.jpg'],{stdio:'ignore'});
const ctx=vm.createContext({console:{log(){},error(){}},Utilities:{base64Encode:b=>Buffer.from(b).toString('base64'),base64Decode:s=>Array.from(Buffer.from(s,'base64')),formatDate:()=> 'Nov 11, 2026'},HtmlService:{XFrameOptionsMode:{ALLOWALL:1},createHtmlOutput:html=>({getContent:()=>html,setTitle(){return this},setXFrameOptionsMode(){return this}})}});
for(const name of ['Code.gs','GalleryPresentation.gs','GalleryStyles.gs','GalleryClient.gs','GalleryDelivery.gs','GalleryMedia.gs'])if(fs.existsSync((process.env.GALLERY_SOURCE||'Backend/GoogleAppsScript')+'/'+name))vm.runInContext(fs.readFileSync((process.env.GALLERY_SOURCE||'Backend/GoogleAppsScript')+'/'+name,'utf8'),ctx);
for(const n of [1,3,6]){const photos=Array.from({length:n},(_,i)=>'photo-0'+(i+1)+'.jpg');const files={};for(const name of [...photos,'receipt-color.jpg']){const b=fs.readFileSync(out+(name.startsWith('photo')?'/photo.jpg':'/receipt.jpg'));files[name]={getBlob:()=>({getBytes:()=>Array.from(b)})};}
const gallery={manifest:{schemaVersion:4,sessionID:'PP-20261111-120000',createdAt:'2026-11-11T04:00:00Z',photos,colorReceipt:'receipt-color.jpg'},filesByName:files};
fs.writeFileSync(path.join(out,'gallery-'+n+'.html'),ctx.renderGalleryPage_(gallery,{},Date.now(),process.env.PROGRESSIVE==='1').getContent());}
console.log('Synthetic JPEG bytes:',fs.statSync(out+'/photo.jpg').size);
