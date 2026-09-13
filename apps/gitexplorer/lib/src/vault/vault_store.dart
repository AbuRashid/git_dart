// Application storage binding: generated record and encryption policies,
// existing UniMSG codec, reusable native capabilities. No plaintext files.
import 'dart:typed_data';
import 'secure_host.dart';
import 'operation_queue.dart';
import 'vault_storage.dart' as storage;
import 'secrets_vault.dart' as policy;
import 'git_credentials.dart' as gitPolicy;
import 'encryption.dart' as encryption;
class VaultStore {
  final AndroidSecureHost host;
  List<dynamic> records = [];
  List<dynamic>? key;
  int epoch = 0;
  String stage = "idle";
  final operations=AsyncOperationQueue();
  VaultStore(this.host);
  Future<void> unlock() async {
    final generation = ++epoch;
    stage='device-authentication';
    await host.call('authenticate');
    if(generation != epoch) throw StateError('Locked');
    stage='reading-document';
    final bytes = await host.call('read', ['vault.umsg']);
    if(generation != epoch) throw StateError('Locked');
    List<dynamic> next;
    if(bytes == null) {
      final created = List<dynamic>.from(await host.call('create-key'));
      if(generation != epoch) throw StateError('Locked');
      key = created;
      next = [];
      await persist(next, create:true);
    } else {
      stage='decoding-document';
      final bundle = storage.run(['unpack',bytes,'android-keystore-v1']) as List;
      key = List<dynamic>.from(bundle[0] as List);
      stage='unlocking-key';
      await host.call('load-key',key!);
      final sealed = bundle[1] as List;
      stage='decrypting-records';
      final plain = await host.drive(encryption.run,List<dynamic>.from(storage.run(['open',sealed,key![0]]) as List)) as Uint8List;
      try {
        stage='decoding-records';
        next = List<dynamic>.from(storage.run(['records',plain]) as List);
        stage='clearing-plaintext';
      } finally { plain.fillRange(0,plain.length,0); }
    }
    if(generation != epoch) { await host.call('lock'); throw StateError('Locked'); }
    records = next;
  }
  Future<void> persist(List<dynamic> next, {bool create=false}) async {
    final generation=epoch;
    final currentKey=key;
    if(currentKey == null) throw StateError('Locked');
    final command = List<dynamic>.from(storage.run(['seal',next,currentKey]) as List);
    final plain = command[1] as Uint8List;
    try {
      final sealed = await host.drive(encryption.run,command);
      if(generation != epoch) throw StateError('Locked');
      final bundle = storage.run(['pack',currentKey,sealed,'android-keystore-v1']);
      await host.call('write',['vault.umsg',bundle,create]);
    } finally { plain.fillRange(0,plain.length,0); }
  }
  Future<void> update(String op,dynamic item) {
    final generation=epoch;
    return operations.run(() async {
    if(generation != epoch || key == null) throw StateError('Locked');
    final next=List<dynamic>.from(policy.run([op,records,item]) as List);
    await persist(next);
    if(generation == epoch) records=next;
    });
  }
  Future<void> lock() async { epoch++; records=[]; key=null; await host.call('lock'); }
  // Git callers supply protocol/host/path/username pairs. No Git transport policy
  // lives here: the same generated adapter is used by the native CLI.
  Future<List<dynamic>> git(String operation,List<dynamic> query) {
    final generation=epoch;
    return operations.run(() async {
    if(generation != epoch || key == null) throw StateError('Unlock the vault first');
    var id='';
    if(operation=='store') {
      final bytes=await host.call('random',[16]) as List;
      id=bytes.map((v)=>(v as int).toRadixString(16).padLeft(2,'0')).join();
    }
    if(generation != epoch) throw StateError('Locked');
    final result=gitPolicy.run([operation,records,query,id]) as List;
    if(operation!='get') {
      final next=List<dynamic>.from(result[0] as List);
      await persist(next);
      if(generation != epoch) throw StateError('Locked');
      records=next;
    }
    return List<dynamic>.from(result[1] as List);
    });
  }
  List<dynamic> get(String id) => List<dynamic>.from(policy.run(['get',records,id]) as List);
  List<Map<String,dynamic>> rows() => [for(final row in policy.run(['list',records]) as List) {'id':row[0],'label':row[2]}];
}
