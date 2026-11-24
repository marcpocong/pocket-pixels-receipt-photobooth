// Isolated private receipt backend. Never add this file to the public gallery project.
// Owner provisions RECEIPTS_ROOT_ID and RECEIPTS_HMAC_SECRET in Script Properties.
// No public read/list route, no sharing changes, no automatic retention trigger.
function doGet() { return ContentService.createTextOutput('Private receipt service.'); }
function doPost(e) {
  var request;
  try {
    if (!e || !e.postData || e.postData.contents.length > 4 * 1024 * 1024) throw Error('invalid');
    request = JSON.parse(e.postData.contents);
    var secret = PropertiesService.getScriptProperties().getProperty('RECEIPTS_HMAC_SECRET');
    if (!secret || secret.length < 32) throw Error('unconfigured');
    if (request.v !== 1 || request.keyId !== 'receipt-v1' || !/^[a-f0-9-]{36}$/.test(request.operationId || '') || !/^[a-f0-9-]{36}$/.test(request.nonce || '')) throw Error('invalid_envelope');
    if (Math.abs(Date.now() - Date.parse(request.timestamp)) > 300000 || !isFinite(Date.parse(request.timestamp))) throw Error('request_expired');
    var signing = ['v1',request.keyId,request.timestamp,request.nonce,request.operationId,request.operation,request.payloadB64].join('\n');
    if (!receiptConstantTime_(request.signature, receiptHMAC_(signing, secret))) throw Error('unauthorized');
    var payload = JSON.parse(Utilities.newBlob(Utilities.base64Decode(request.payloadB64)).getDataAsString());
    var rootId = PropertiesService.getScriptProperties().getProperty('RECEIPTS_ROOT_ID');
    assertReceiptPrivate_(rootId);
    var result;
    if (request.operation === 'store') result = storePrivateReceipt_(rootId, request.operationId, payload);
    else if (request.operation === 'read') result = readPrivateReceipt_(rootId, request.operationId, payload);
    else if (request.operation === 'retention') result = establishReceiptRetention_(payload);
    else if (request.operation === 'trash') result = trashPrivateReceipt_(rootId, request.operationId, payload);
    else throw Error('invalid_operation');
    return receiptResponse_(request, result, secret);
  } catch (failure) {
    // Fixed messages only. Never log envelopes, image bytes, receiving details or secrets.
    var code = /^(?:unauthorized|unconfigured|invalid_envelope|request_expired|invalid|invalid_operation|invalid_private_root|unsafe_permissions|trashed|duplicate_private_folder|duplicate_private_journal|invalid_image|checksum_mismatch|identity_conflict|event|busy|storage_mismatch|upload_unconfirmed|drive_unconfirmed|drive_http_[0-9]{3}|not_found|parent_changed|changed|retention_not_approved)$/.test(failure.message || '') ? failure.message : 'execution_failure';
    return ContentService.createTextOutput(JSON.stringify({ok:false,error:'receipt_operation_unconfirmed',code:code})).setMimeType(ContentService.MimeType.JSON);
  }
}
function receiptResponse_(request, result, secret) {
  var data = Utilities.base64Encode(JSON.stringify(result), Utilities.Charset.UTF_8);
  return ContentService.createTextOutput(JSON.stringify({operationId:request.operationId,operation:request.operation,payloadB64:data,
    signature:receiptHMAC_(request.operationId+'\n'+request.operation+'\n'+data,secret)})).setMimeType(ContentService.MimeType.JSON);
}
function receiptHMAC_(value, secret) { return receiptHex_(Utilities.computeHmacSha256Signature(value,secret,Utilities.Charset.UTF_8)); }
function receiptHex_(bytes) { return bytes.map(function(b){return ('0'+((b+256)%256).toString(16)).slice(-2);}).join(''); }
function receiptConstantTime_(a,b) { if(typeof a!=='string'||a.length!==b.length)return false;var diff=0;for(var i=0;i<a.length;i++)diff|=a.charCodeAt(i)^b.charCodeAt(i);return diff===0; }
function receiptDrive_(path, options) {
  options=options||{};options.headers={Authorization:'Bearer '+ScriptApp.getOAuthToken()};options.muteHttpExceptions=true;
  if(options.payload && typeof options.payload !== 'string' && !(options.payload instanceof Array)) {options.payload=JSON.stringify(options.payload);options.contentType='application/json';}
  var response=UrlFetchApp.fetch('https://www.googleapis.com/'+path,options),code=response.getResponseCode();
  if(code<200||code>=300)throw Error('drive_http_'+code);
  return JSON.parse(response.getContentText()||'{}');
}
function assertReceiptPrivate_(id,allowTrashed) {
  if(!/^[A-Za-z0-9_-]{10,200}$/.test(id||''))throw Error('invalid_private_root');
  var item=receiptDrive_('drive/v3/files/'+id+'?fields=id,trashed,parents,mimeType');
  if(item.trashed&&!allowTrashed)throw Error('trashed');
  var permissions=receiptDrive_('drive/v3/files/'+id+'/permissions?fields=permissions(type,role)').permissions||[];
  if(permissions.length!==1||permissions[0].type!=='user'||permissions[0].role!=='owner')throw Error('unsafe_permissions');
  return item;
}
function receiptFolder_(parent,name) {
  var folders=parent.getFoldersByName(name),folder=folders.hasNext()?folders.next():null;
  if(folders.hasNext())throw Error('duplicate_private_folder');
  folder=folder||parent.createFolder(name);assertReceiptPrivate_(folder.getId());return folder;
}
function receiptJournal_(root,id) {
  var folder=receiptFolder_(DriveApp.getFolderById(root),'.receipt-journals');
  var files=folder.getFilesByName(id+'.json'),file=files.hasNext()?files.next():null;
  if(files.hasNext())throw Error('duplicate_private_journal');
  if(file)assertReceiptPrivate_(file.getId());
  return {folder:folder,file:file,value:file?JSON.parse(file.getBlob().getDataAsString()):null};
}
function storePrivateReceipt_(root,id,p) {
  if(!/^[a-f0-9-]{36}$/.test(p.checkoutId||'')||!/^\d{4}$/.test(p.year)||!/^\d{2}$/.test(p.month)||!/^\d{4}-\d{2}-\d{2}$/.test(p.date)||
    !/^[a-f0-9]{64}$/.test(p.sha256||'')||['image/jpeg','image/png'].indexOf(p.mimeType)<0||p.bytes>2097152||p.bytes<24)throw Error('invalid_image');
  var bytes=Utilities.base64Decode(p.base64);
  if(bytes.length!==p.bytes||receiptHex_(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes))!==p.sha256)throw Error('checksum_mismatch');
  var lock=LockService.getScriptLock();if(!lock.tryLock(10000))throw Error('busy');
  try {
    var journal=receiptJournal_(root,id),record=journal.value;
    if(record&&(record.sha256!==p.sha256||record.checkoutId!==p.checkoutId||record.bytes!==p.bytes))throw Error('identity_conflict');
    if(!record){
      var parent=receiptFolder_(DriveApp.getFolderById(root),p.year);parent=receiptFolder_(parent,p.month);
      if(p.eventId){if(!/^[A-Za-z0-9._:-]{1,100}$/.test(p.eventId))throw Error('event');parent=receiptFolder_(receiptFolder_(parent,'Events'),p.eventId);}
      else parent=receiptFolder_(receiptFolder_(parent,'Regular Booth'),p.date);
      var generated=receiptDrive_('drive/v3/files/generateIds?count=1&space=drive').ids[0];
      record={id:id,checkoutId:p.checkoutId,fileId:generated,parentId:parent.getId(),sha256:p.sha256,bytes:p.bytes,mimeType:p.mimeType,createdAt:Date.now()};
      // Persist reserved identity before the first media mutation. Retrying reuses the same ID.
      journal.file=journal.folder.createFile(id+'.json',JSON.stringify(record),'application/json');journal.value=record;assertReceiptPrivate_(journal.file.getId());
    }
    assertReceiptPrivate_(record.parentId);
    var existing;
    try {existing=receiptDrive_('drive/v3/files/'+record.fileId+'?fields=id,size,sha256Checksum');}catch(_){existing=null;}
    if(!existing){receiptDrive_('drive/v3/files?fields=id',{method:'post',payload:{id:record.fileId,name:p.checkoutId+'-'+id+(p.mimeType==='image/png'?'.png':'.jpg'),mimeType:p.mimeType,parents:[record.parentId]}});}
    if(!existing||Number(existing.size)!==p.bytes||existing.sha256Checksum!==p.sha256){
      var response=UrlFetchApp.fetch('https://www.googleapis.com/upload/drive/v3/files/'+record.fileId+'?uploadType=media',{method:'patch',headers:{Authorization:'Bearer '+ScriptApp.getOAuthToken()},contentType:p.mimeType,payload:bytes,muteHttpExceptions:true});
      if(response.getResponseCode()<200||response.getResponseCode()>=300)throw Error('upload_unconfirmed');
    }
    var stored=assertReceiptPrivate_(record.fileId);
    var proof=receiptDrive_('drive/v3/files/'+record.fileId+'?fields=id,name,mimeType,size,sha256Checksum,parents,trashed');
    if(proof.trashed||Number(proof.size)!==p.bytes||proof.mimeType!==p.mimeType||proof.sha256Checksum!==p.sha256||proof.parents.length!==1||proof.parents[0]!==record.parentId)throw Error('storage_mismatch');
    record.storedAt=record.storedAt||Date.now();journal.file.setContent(JSON.stringify(record));
    return {ok:true,private:true,fileId:record.fileId,folderURL:'https://drive.google.com/drive/folders/'+record.parentId,sha256:p.sha256,bytes:p.bytes};
  }finally{lock.releaseLock();}
}
function readPrivateReceipt_(root,id,p) {
  var journal=receiptJournal_(root,id),record=journal.value;
  if(!record||record.fileId!==p.fileId||record.sha256!==p.sha256||!record.storedAt)throw Error('not_found');
  assertReceiptPrivate_(record.parentId);var file=assertReceiptPrivate_(record.fileId);
  if(file.parents.length!==1||file.parents[0]!==record.parentId)throw Error('parent_changed');
  var blob=DriveApp.getFileById(record.fileId).getBlob(),bytes=blob.getBytes();
  if(bytes.length!==record.bytes||receiptHex_(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes))!==record.sha256)throw Error('changed');
  return {ok:true,base64:Utilities.base64Encode(bytes)};
}
function trashPrivateReceipt_(root,id,p) {
  var days=Number(PropertiesService.getScriptProperties().getProperty('RECEIPT_RETENTION_DAYS')||0),record=receiptJournal_(root,id).value;
  if(!days||days<1||p.retentionApproved!==true||!record||record.fileId!==p.fileId||Date.now()-record.createdAt<days*86400000)throw Error('retention_not_approved');
  assertReceiptPrivate_(record.parentId);var file=assertReceiptPrivate_(record.fileId,true);
  if(file.parents.length!==1||file.parents[0]!==record.parentId)throw Error('parent_changed');
  if(file.trashed)return {ok:true,trashed:true};
  receiptDrive_('drive/v3/files/'+record.fileId,{method:'patch',payload:{trashed:true}});
  return {ok:true,trashed:true}; // Recoverable Trash only; financial association/journal remain.
}

function establishReceiptRetention_(p) {
  if(p.approved!==true||!Number.isInteger(p.days)||p.days<1||p.days>3650)throw Error('retention_not_approved');
  PropertiesService.getScriptProperties().setProperty('RECEIPT_RETENTION_DAYS',String(p.days));
  return {ok:true,days:p.days}; // Deliberately creates no cleanup trigger.
}
