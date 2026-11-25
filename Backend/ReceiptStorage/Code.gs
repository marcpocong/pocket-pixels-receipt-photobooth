// Isolated private receipt backend. Never add this file to the public gallery project.
// Owner provisions RECEIPTS_ROOT_ID and RECEIPTS_HMAC_SECRET in Script Properties.
// No public read/list route, no sharing changes, no automatic retention trigger.
function doGet() { return ContentService.createTextOutput('Private receipt service.'); }
function doPost(e) {
  var request;
  try {
    if (!e || !e.postData || e.postData.contents.length > 4 * 1024 * 1024) throw Error('invalid');
    request = JSON.parse(e.postData.contents);
    var scope = request.keyId === 'receipt-live-v1' ? '_LIVE' : '';
    var properties = PropertiesService.getScriptProperties();
    var secret = properties.getProperty('RECEIPTS_HMAC_SECRET' + scope);
    if (!secret || secret.length < 32) throw Error('unconfigured');
    if (request.v !== 1 || !['receipt-v1', 'receipt-live-v1'].includes(request.keyId) || !/^[a-f0-9-]{36}$/.test(request.operationId || '') || !/^[a-f0-9-]{36}$/.test(request.nonce || '')) throw Error('invalid_envelope');
    if (Math.abs(Date.now() - Date.parse(request.timestamp)) > 300000 || !isFinite(Date.parse(request.timestamp))) throw Error('request_expired');
    var signing = ['v1',request.keyId,request.timestamp,request.nonce,request.operationId,request.operation,request.payloadB64].join('\n');
    if (!receiptConstantTime_(request.signature, receiptHMAC_(signing, secret))) throw Error('unauthorized');
    var payload = JSON.parse(Utilities.newBlob(Utilities.base64Decode(request.payloadB64)).getDataAsString());
    var rootId = properties.getProperty('RECEIPTS_ROOT_ID' + scope);
    if (scope && rootId === properties.getProperty('RECEIPTS_ROOT_ID')) throw Error('invalid_private_root');
    var result;
    if (request.operation === 'store') result = storePrivateReceipt_(rootId, request.operationId, payload);
    else {
      var root = assertReceiptPrivate_(rootId);
      if (request.operation === 'ready') {
        if (root.mimeType !== 'application/vnd.google-apps.folder' || root.capabilities?.canAddChildren !== true) throw Error('invalid_private_root');
        result = {ok:true, ready:true};
      }
      else if (request.operation === 'read') result = readPrivateReceipt_(rootId, request.operationId, payload);
      else if (request.operation === 'retention') result = establishReceiptRetention_(payload, scope);
      else if (request.operation === 'trash') result = trashPrivateReceipt_(rootId, request.operationId, payload, scope);
      else throw Error('invalid_operation');
    }
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
  return receiptDriveResponse_(UrlFetchApp.fetch('https://www.googleapis.com/'+path,options));
}
function receiptDriveResponse_(response) {
  var code=response.getResponseCode();
  if(code<200||code>=300)throw Error('drive_http_'+code);
  return JSON.parse(response.getContentText()||'{}');
}
function receiptDriveParallel_(paths) {
  var headers={Authorization:'Bearer '+ScriptApp.getOAuthToken()};
  return UrlFetchApp.fetchAll(paths.map(function(path){return {
    url:'https://www.googleapis.com/'+path,headers:headers,muteHttpExceptions:true
  };})).map(receiptDriveResponse_);
}
var receiptFolderFields_ = 'id,trashed,parents,mimeType,permissions(type,role)';
var receiptMediaFields_ = receiptFolderFields_ + ',size,sha256Checksum';
function assertReceiptOwnerOnly_(item,allowTrashed) {
  if(item.trashed&&!allowTrashed)throw Error('trashed');
  // My Drive can return the full ACL with file metadata. Keep an explicit ACL read
  // when the response omits it, and fail closed on a paginated permission set.
  var permissions=item.permissions;
  if(!Array.isArray(permissions)){
    var acl=receiptDrive_('drive/v3/files/'+item.id+'/permissions?pageSize=2&fields=nextPageToken,permissions(type,role)');
    if(acl.nextPageToken)throw Error('unsafe_permissions');
    permissions=acl.permissions||[];
  }
  if(permissions.length!==1||permissions[0].type!=='user'||permissions[0].role!=='owner')throw Error('unsafe_permissions');
  return item;
}
function assertReceiptPrivate_(id,allowTrashed,fields) {
  if(!/^[A-Za-z0-9_-]{10,200}$/.test(id||''))throw Error('invalid_private_root');
  var item=receiptDrive_('drive/v3/files/'+id+'?fields='+(fields||receiptFolderFields_+',capabilities(canAddChildren)'));
  return verifyPrivateReceiptItem_(item,id,allowTrashed);
}
function verifyPrivateReceiptItem_(item,id,allowTrashed) {
  if(item.id!==id)throw Error('storage_mismatch');
  return assertReceiptOwnerOnly_(item,allowTrashed);
}
var receiptFolderMime_ = 'application/vnd.google-apps.folder';
function receiptFolderLookup_(parentId,name) {
  var query="'"+parentId+"' in parents and name='"+name+"' and mimeType='"+receiptFolderMime_+"' and trashed=false";
  var fields='nextPageToken,incompleteSearch,files('+receiptFolderFields_+')';
  return 'drive/v3/files?q='+encodeURIComponent(query)+'&pageSize=2&fields='+fields;
}
function receiptFolderMatch_(search) {
  var folders=search.files||[];
  if(search.nextPageToken||search.incompleteSearch||folders.length>1)throw Error('duplicate_private_folder');
  return folders[0];
}
function privateReceiptFolderId_(folder,parentId) {
  if(folder.mimeType!==receiptFolderMime_||!folder.parents||folder.parents.length!==1||folder.parents[0]!==parentId)throw Error('parent_changed');
  return assertReceiptOwnerOnly_(folder).id;
}
function receiptFolder_(parentId,name) {
  var matched=receiptFolderMatch_(receiptDrive_(receiptFolderLookup_(parentId,name)));
  var folder=matched||receiptDrive_('drive/v3/files?fields='+receiptFolderFields_,{method:'post',payload:{name:name,mimeType:receiptFolderMime_,parents:[parentId]}});
  return privateReceiptFolderId_(folder,parentId);
}
function receiptDestinationPlan_(root,p) {
  var names=[p.year,p.month,p.eventId?'Events':'Regular Booth',p.eventId||p.date];
  var key='receipt-path:'+receiptHex_(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,JSON.stringify([root,names])));
  var cache,known;
  try {
    cache=CacheService.getScriptCache();
    known=JSON.parse(cache.get(key)||'null');
  } catch (_) { /* The path can be resolved without the cache. */ }
  if(!Array.isArray(known)||known.length!==names.length||!known.every(function(id){return /^[A-Za-z0-9_-]{10,200}$/.test(id);}))known=null;
  return {names:names,key:key,cache:cache,known:known,parents:known?[root].concat(known.slice(0,-1)):null};
}
function receiptDestinationLookups_(plan) {
  return plan.names.map(function(name,index){return receiptFolderLookup_(plan.parents[index],name);});
}
function verifyReceiptDestination_(plan,results) {
  if(results.length!==plan.names.length||!results.every(function(result,index){
    var matched=receiptFolderMatch_(result);
    return matched&&privateReceiptFolderId_(matched,plan.parents[index])===plan.known[index];
  }))return null;
  return plan.known[plan.known.length-1];
}
function receiptDestination_(root,p) {
  var plan=receiptDestinationPlan_(root,p);
  if(plan.known){
    try {
      var destination=verifyReceiptDestination_(plan,receiptDriveParallel_(receiptDestinationLookups_(plan)));
      if(destination)return destination;
    } catch (_) { /* Rediscover the current path below. */ }
  }
  var resolved=[],parentId=root;
  plan.names.forEach(function(name){parentId=receiptFolder_(parentId,name);resolved.push(parentId);});
  try {if(plan.cache)plan.cache.put(plan.key,JSON.stringify(resolved),1800);} catch (_) { /* The verified path is enough. */ }
  return parentId;
}
function receiptJournalLookup_(folderId,id) {
  var query="'"+folderId+"' in parents and name='"+id+".json' and trashed=false";
  return 'drive/v3/files?q='+encodeURIComponent(query)+'&pageSize=2&fields=nextPageToken,incompleteSearch,files('+receiptFolderFields_+')';
}
function receiptJournal_(root,id) {
  var cache,key='receipt-journals:'+root,folderId,search;
  try {
    cache=CacheService.getScriptCache();
    var known=cache.get(key);
    if(/^[A-Za-z0-9_-]{10,200}$/.test(known||'')){
      var results=receiptDriveParallel_([receiptFolderLookup_(root,'.receipt-journals'),receiptJournalLookup_(known,id)]);
      var match=receiptFolderMatch_(results[0]);
      if(match&&privateReceiptFolderId_(match,root)===known){folderId=known;search=results[1];}
    }
  } catch (_) { /* Resolve the current path below. */ }
  if(!search){
    folderId=receiptFolder_(root,'.receipt-journals');
    search=receiptDrive_(receiptJournalLookup_(folderId,id));
    try {if(cache)cache.put(key,folderId,1800);} catch (_) { /* The verified path is enough. */ }
  }
  return receiptJournalFromSearch_(folderId,search);
}
function receiptJournalFromSearch_(folderId,search) {
  var files=search.files||[];
  if(search.nextPageToken||search.incompleteSearch||files.length>1)throw Error('duplicate_private_journal');
  if(!files.length)return {folderId:folderId,value:null};
  var file=assertReceiptOwnerOnly_(files[0]);
  if(file.mimeType!=='application/json'||file.parents?.length!==1||file.parents[0]!==folderId)throw Error('parent_changed');
  return {folderId:folderId,value:receiptDrive_('drive/v3/files/'+file.id+'?alt=media')};
}
function prepareWarmReceipt_(root,id,p) {
  if(!/^[A-Za-z0-9_-]{10,200}$/.test(root||''))throw Error('invalid_private_root');
  try {
    var plan=receiptDestinationPlan_(root,p),folderId=plan.cache?.get('receipt-journals:'+root);
    if(!plan.known||!/^[A-Za-z0-9_-]{10,200}$/.test(folderId||''))return null;
    // Cached IDs are only lookup hints. Verify root, namespace and every destination
    // folder from fresh Drive results before creating any journal or uploading bytes.
    var paths=[
      'drive/v3/files/'+root+'?fields='+receiptFolderFields_,
      receiptFolderLookup_(root,'.receipt-journals'),
      receiptJournalLookup_(folderId,id),
      'drive/v3/files/generateIds?count=1&space=drive'
    ].concat(receiptDestinationLookups_(plan));
    var results=receiptDriveParallel_(paths);
    verifyPrivateReceiptItem_(results[0],root);
    var journalFolder=receiptFolderMatch_(results[1]);
    if(!journalFolder||privateReceiptFolderId_(journalFolder,root)!==folderId)return null;
    var parentId=verifyReceiptDestination_(plan,results.slice(4));
    var fileId=results[3].ids?.[0];
    if(!parentId||!/^[A-Za-z0-9_-]{10,200}$/.test(fileId||''))return null;
    return {journal:receiptJournalFromSearch_(folderId,results[2]),parentId:parentId,fileId:fileId};
  } catch (_) { return null; }
}
function withReceiptLock_(action) {
  var lock=LockService.getScriptLock();
  if(!lock.tryLock(10000))throw Error('busy');
  try {return action();}finally{lock.releaseLock();}
}
function reservePrivateReceipt_(root,id,p) {
  return withReceiptLock_(function(){
    var warm=prepareWarmReceipt_(root,id,p);
    if(!warm)assertReceiptPrivate_(root);
    var journal=warm?warm.journal:receiptJournal_(root,id),record=journal.value;
    if(record){
      if(record.sha256!==p.sha256||record.checkoutId!==p.checkoutId||record.bytes!==p.bytes||record.mimeType!==p.mimeType)throw Error('identity_conflict');
      return record;
    }
    var parent=warm?warm.parentId:receiptDestination_(root,p);
    var fileId=warm?warm.fileId:receiptDrive_('drive/v3/files/generateIds?count=1&space=drive').ids[0];
    record={id:id,checkoutId:p.checkoutId,fileId:fileId,parentId:parent,sha256:p.sha256,bytes:p.bytes,mimeType:p.mimeType,createdAt:Date.now()};
    // The reserved file ID is durable before any media write.
    var name=id+'.json';
    var file=Drive.Files.create({name:name,mimeType:'application/json',parents:[journal.folderId]},
      Utilities.newBlob(JSON.stringify(record),'application/json',name),{fields:receiptFolderFields_});
    var verified=assertReceiptOwnerOnly_(file);
    if(verified.id==null||verified.mimeType!=='application/json'||verified.parents?.length!==1||verified.parents[0]!==journal.folderId)throw Error('storage_mismatch');
    return record;
  });
}
function uploadPrivateReceipt_(record,bytes) {
  var fileId=record.fileId, name=record.checkoutId+'-'+record.id+(record.mimeType==='image/png'?'.png':'.jpg');
  var blob=Utilities.newBlob(bytes,record.mimeType,name);
  var proof;
  try {
    proof=Drive.Files.create({id:fileId,name:name,mimeType:record.mimeType,parents:[record.parentId]},blob,{fields:receiptMediaFields_});
  } catch (_) {
    // A retry after a lost response or a concurrent create sees the same reserved file.
    proof=assertReceiptPrivate_(fileId,false,receiptMediaFields_);
    if(proof.mimeType===record.mimeType&&proof.parents?.length===1&&proof.parents[0]===record.parentId&&proof.size==='0'){
      // Older deployments reserved an empty file before patching its media.
      proof=Drive.Files.update({},fileId,blob,{fields:receiptMediaFields_});
    }
  }
  // Upload responses can omit checksums while metadata catches up.
  if(!proof.sha256Checksum||!Array.isArray(proof.permissions))return assertReceiptPrivate_(fileId,false,receiptMediaFields_);
  return assertReceiptOwnerOnly_(proof);
}
function verifyReceiptMedia_(proof,record) {
  if(proof.id!==record.fileId||Number(proof.size)!==record.bytes||proof.mimeType!==record.mimeType||proof.sha256Checksum!==record.sha256)throw Error('storage_mismatch');
  if(proof.parents?.length!==1||proof.parents[0]!==record.parentId)throw Error('parent_changed');
}
function storePrivateReceipt_(root,id,p) {
  if(!/^[a-f0-9-]{36}$/.test(p.checkoutId||'')||!/^\d{4}$/.test(p.year)||!/^\d{2}$/.test(p.month)||!/^\d{4}-\d{2}-\d{2}$/.test(p.date)||
    !/^[a-f0-9]{64}$/.test(p.sha256||'')||['image/jpeg','image/png'].indexOf(p.mimeType)<0||p.bytes>2097152||p.bytes<24)throw Error('invalid_image');
  if(p.eventId&&!/^[A-Za-z0-9._:-]{1,100}$/.test(p.eventId))throw Error('event');
  var bytes=Utilities.base64Decode(p.base64);
  if(bytes.length!==p.bytes||receiptHex_(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes))!==p.sha256)throw Error('checksum_mismatch');
  var record=reservePrivateReceipt_(root,id,p);
  assertReceiptPrivate_(record.parentId);
  // Uploads for different receipts need not wait for each other once their IDs are reserved.
  var proof=record.storedAt?assertReceiptPrivate_(record.fileId,false,receiptMediaFields_):uploadPrivateReceipt_(record,bytes);
  verifyReceiptMedia_(proof,record);
  // The Worker durably records the signed storage proof. The Drive journal
  // remains an immutable reservation used to reconcile the same file on retry.
  return {ok:true,private:true,fileId:record.fileId,folderURL:'https://drive.google.com/drive/folders/'+record.parentId,sha256:p.sha256,bytes:p.bytes};
}
function readPrivateReceipt_(root,id,p) {
  var journal=receiptJournal_(root,id),record=journal.value;
  if(!record||record.fileId!==p.fileId||record.sha256!==p.sha256)throw Error('not_found');
  assertReceiptPrivate_(record.parentId);
  verifyReceiptMedia_(assertReceiptPrivate_(record.fileId,false,receiptMediaFields_),record);
  var blob=DriveApp.getFileById(record.fileId).getBlob(),bytes=blob.getBytes();
  if(bytes.length!==record.bytes||receiptHex_(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes))!==record.sha256)throw Error('changed');
  return {ok:true,base64:Utilities.base64Encode(bytes)};
}
function trashPrivateReceipt_(root,id,p,scope) {
  var days=Number(PropertiesService.getScriptProperties().getProperty('RECEIPT_RETENTION_DAYS' + (scope || ''))||0),record=receiptJournal_(root,id).value;
  if(!days||days<1||p.retentionApproved!==true||!record||record.fileId!==p.fileId||Date.now()-record.createdAt<days*86400000)throw Error('retention_not_approved');
  assertReceiptPrivate_(record.parentId);var file=assertReceiptPrivate_(record.fileId,true);
  if(file.parents.length!==1||file.parents[0]!==record.parentId)throw Error('parent_changed');
  if(file.trashed)return {ok:true,trashed:true};
  receiptDrive_('drive/v3/files/'+record.fileId,{method:'patch',payload:{trashed:true}});
  return {ok:true,trashed:true}; // Recoverable Trash only; financial association/journal remain.
}

function establishReceiptRetention_(p,scope) {
  if(p.approved!==true||!Number.isInteger(p.days)||p.days<1||p.days>3650)throw Error('retention_not_approved');
  PropertiesService.getScriptProperties().setProperty('RECEIPT_RETENTION_DAYS' + (scope || ''),String(p.days));
  return {ok:true,days:p.days}; // Deliberately creates no cleanup trigger.
}
