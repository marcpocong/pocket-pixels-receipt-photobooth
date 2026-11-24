// Bounded JPEG/PNG validation and metadata removal, with no image decoder dependency.
// Raw guest bytes are never served as HTML/SVG or sent to public gallery storage.
export const RECEIPT_MAX_BYTES = 2 * 1024 * 1024;
const reject = () => { throw Object.assign(new Error("Choose a valid JPEG or PNG receipt under 2 MiB and 25 megapixels."), { status:422, code:"invalid_receipt_image" }); };
export function normalizeReceipt(bytes, mime) {
    if (!(bytes instanceof Uint8Array) || bytes.length < 24 || bytes.length > RECEIPT_MAX_BYTES) reject();
    let width, height, parts = [];
    if (mime === "image/jpeg") {
        if (bytes[0] !== 255 || bytes[1] !== 216 || bytes.at(-2) !== 255 || bytes.at(-1) !== 217) reject();
        parts.push(bytes.slice(0,2)); let offset=2, sawScan=false, ended=false;
        while(offset<bytes.length) {
            if(bytes[offset++]!==255)reject();while(bytes[offset]===255)offset++;
            const marker=bytes[offset++];
            if(marker===217){if(offset!==bytes.length||!sawScan)reject();parts.push(new Uint8Array([255,217]));ended=true;break;}
            if(![192,193,194,196,219,221,218,254].includes(marker)&&!(marker>=224&&marker<=239))reject();
            const length=bytes[offset]*256+bytes[offset+1];
            if(length<2||offset+length>bytes.length-2)reject();
            if([192,193,194].includes(marker)){
                if(length<8||width)reject();height=bytes[offset+3]*256+bytes[offset+4];width=bytes[offset+5]*256+bytes[offset+6];
            }
            const start=offset-2;
            if(!(marker>=224&&marker<=239)&&marker!==254)parts.push(bytes.slice(start,offset+length));
            offset+=length;
            if(marker===218){
                if(!width||length<6)reject();sawScan=true;const scanStart=offset;
                while(offset<bytes.length-1){
                    if(bytes[offset]!==255){offset++;continue;}
                    const next=bytes[offset+1];
                    if(next===0||next>=208&&next<=215){offset+=2;continue;}
                    break;
                }
                parts.push(bytes.slice(scanStart,offset));
            }
        }
        if(!ended)reject();
        // Reject embedded active content even in scan data; conservative handling for receipts.
        const tail=new TextDecoder("latin1").decode(bytes);
        if(/<\s*(?:html|script|svg|iframe)|<\?php/i.test(tail))reject();
    } else if(mime === "image/png") {
        if(![137,80,78,71,13,10,26,10].every((v,i)=>bytes[i]===v))reject();
        parts.push(bytes.slice(0,8));let offset=8, ended=false, imageData=false, header=false;
        const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength);
        while(offset+12<=bytes.length) {
            const length=view.getUint32(offset),end=offset+length+12;if(end>bytes.length)reject();
            const type=String.fromCharCode(...bytes.slice(offset+4,offset+8));
            if(!/^[A-Za-z]{4}$/.test(type) || crc32(bytes.subarray(offset+4,end-4))!==view.getUint32(end-4))reject();
            if(type==='IHDR') {if(header||offset!==8||length!==13)reject();header=true;width=view.getUint32(offset+8);height=view.getUint32(offset+12);}
            if(!header)reject();if(type==='IDAT')imageData=true;
            if(['IHDR','PLTE','tRNS','IDAT','IEND'].includes(type))parts.push(bytes.slice(offset,end));
            else if(type[0]===type[0].toUpperCase())reject();
            offset=end;if(type==='IEND'){if(length!==0||offset!==bytes.length||!imageData)reject();ended=true;break;}
        }
        if(!ended)reject();
    } else reject();
    if(!width||!height||width*height>25_000_000||width>10000||height>10000)reject();
    const size=parts.reduce((n,p)=>n+p.length,0), result=new Uint8Array(size);let offset=0;
    for(const p of parts){result.set(p,offset);offset+=p.length;}
    return { bytes:result,mime,width,height };
}
function crc32(data){let c=0xffffffff;for(const byte of data){c^=byte;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0);}return (c^0xffffffff)>>>0;}
