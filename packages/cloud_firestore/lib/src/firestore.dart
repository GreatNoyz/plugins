// Copyright 2017, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of cloud_firestore;

/// The entry point for accessing a Firestore.
///
/// You can get an instance by calling [Firestore.instance].
class Firestore {
  @visibleForTesting
  static const MethodChannel channel = const MethodChannel(
    'plugins.flutter.io/cloud_firestore',
    const StandardMethodCodec(const FirestoreMessageCodec()),
  );

  static final Map<int, StreamController<QuerySnapshot>> _queryObservers =
      <int, StreamController<QuerySnapshot>>{};

  static final Map<int, StreamController<DocumentSnapshot>> _documentObservers =
      <int, StreamController<DocumentSnapshot>>{};

  static final Map<int, TransactionHandler> _transactionHandlers =
      <int, TransactionHandler>{};
  static int _transactionHandlerId = 0;

  Firestore._() {
    channel.setMethodCallHandler((MethodCall call) {
      if (call.method == 'QuerySnapshot') {
        final QuerySnapshot snapshot =
            new QuerySnapshot._(call.arguments, this);
        _queryObservers[call.arguments['handle']].add(snapshot);
      } else if (call.method == 'DocumentSnapshot') {
        final DocumentSnapshot snapshot = new DocumentSnapshot._(
          call.arguments['path'],
          _asStringKeyedMap(call.arguments['data']),
          this,
        );
        _documentObservers[call.arguments['handle']].add(snapshot);
      } else if (call.method == 'DoTransaction') {
        final int transactionId = call.arguments['transactionId'];
        return _transactionHandlers[transactionId](
          new Transaction(transactionId),
        );
      }
    });
  }

  static Firestore _instance = new Firestore._();

  /// Gets the instance of Firestore for the default Firebase app.
  static Firestore get instance => _instance;

  /// Gets a [CollectionReference] for the specified Firestore path.
  CollectionReference collection(String path) {
    assert(path != null);
    return new CollectionReference._(this, path.split('/'));
  }

  /// Gets a [DocumentReference] for the specified Firestore path.
  DocumentReference document(String path) {
    assert(path != null);
    return new DocumentReference._(this, path.split('/'));
  }

  /// Creates a write batch, used for performing multiple writes as a single
  /// atomic operation.
  ///
  /// Unlike transactions, write batches are persisted offline and therefore are
  /// preferable when you don’t need to condition your writes on read data.
  WriteBatch batch() => new WriteBatch._();

  /// Executes the given TransactionHandler and then attempts to commit the
  /// changes applied within an atomic transaction.
  ///
  /// In the TransactionHandler, a set of reads and writes can be performed
  /// atomically using the Transaction object passed to the TransactionHandler.
  /// After the TransactionHandler is run, Firestore will attempt to apply the
  /// changes to the server. If any of the data read has been modified outside
  /// of this transaction since being read, then the transaction will be
  /// retried by executing the updateBlock again. If the transaction still
  /// fails after 5 retries, then the transaction will fail.
  ///
  /// The TransactionHandler may be executed multiple times, it should be able
  /// to handle multiple executions.
  ///
  /// Data accessed with the transaction will not reflect local changes that
  /// have not been committed. For this reason, it is required that all
  /// reads are performed before any writes. Transactions must be performed
  /// while online. Otherwise, reads will fail, and the final commit will fail.
  ///
  /// By default transactions are limited to 5 seconds of execution time. This
  /// timeout can be adjusted by setting the timeout parameter.
  Future<Map<String, dynamic>> runTransaction(
      TransactionHandler transactionHandler,
      {Duration timeout: const Duration(seconds: 5)}) async {
    assert(timeout.inMilliseconds > 0,
        'Transaction timeout must be more than 0 milliseconds');
    final int transactionId = _transactionHandlerId++;
    _transactionHandlers[transactionId] = transactionHandler;
    final Map<dynamic, dynamic> result = await channel.invokeMethod(
        'Firestore#runTransaction', <String, dynamic>{
      'transactionId': transactionId,
      'transactionTimeout': timeout.inMilliseconds
    });
    return result?.cast<String, dynamic>() ?? <String, dynamic>{};
  }
}

typedef Future<dynamic> TransactionHandler(Transaction transaction);

class Transaction {
  int _transactionId;

  Transaction(this._transactionId);

  Future<DocumentSnapshot> get(DocumentReference documentReference) async {
    final dynamic result = await Firestore.channel
        .invokeMethod('Transaction#get', <String, dynamic>{
      'transactionId': _transactionId,
      'path': documentReference.path,
    });
    if (result != null) {
      return new DocumentSnapshot._(documentReference.path,
          result['data'].cast<String, dynamic>(), Firestore.instance);
    } else {
      return null;
    }
  }

  Future<void> delete(DocumentReference documentReference) async {
    return Firestore.channel
        .invokeMethod('Transaction#delete', <String, dynamic>{
      'transactionId': _transactionId,
      'path': documentReference.path,
    });
  }

  Future<void> update(
      DocumentReference documentReference, Map<String, dynamic> data) async {
    return Firestore.channel
        .invokeMethod('Transaction#update', <String, dynamic>{
      'transactionId': _transactionId,
      'path': documentReference.path,
      'data': data,
    });
  }

  Future<void> set(
      DocumentReference documentReference, Map<String, dynamic> data) async {
    return Firestore.channel.invokeMethod('Transaction#set', <String, dynamic>{
      'transactionId': _transactionId,
      'path': documentReference.path,
      'data': data,
    });
  }
}

class FirestoreMessageCodec extends StandardMessageCodec {
  const FirestoreMessageCodec();

  static const int _kDateTime = 128;
  static const int _kGeoPoint = 129;
  static const int _kDocumentReference = 130;

  @override
  void writeValue(WriteBuffer buffer, dynamic value) {
    if (value is DateTime) {
      buffer.putUint8(_kDateTime);
      buffer.putInt64(value.millisecondsSinceEpoch);
    } else if (value is GeoPoint) {
      buffer.putUint8(_kGeoPoint);
      buffer.putFloat64(value.latitude);
      buffer.putFloat64(value.longitude);
    } else if (value is DocumentReference) {
      buffer.putUint8(_kDocumentReference);
      final List<int> bytes = utf8.encoder.convert(value.path);
      writeSize(buffer, bytes.length);
      buffer.putUint8List(bytes);
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  dynamic readValueOfType(int type, ReadBuffer buffer) {
    switch (type) {
      case _kDateTime:
        return new DateTime.fromMillisecondsSinceEpoch(buffer.getInt64());
      case _kGeoPoint:
        return new GeoPoint(buffer.getFloat64(), buffer.getFloat64());
      case _kDocumentReference:
        final int length = readSize(buffer);
        final String path = utf8.decoder.convert(buffer.getUint8List(length));
        return Firestore.instance.document(path);
      default:
        return super.readValueOfType(type, buffer);
    }
  }
}

class GeoPoint {
  final double latitude;
  final double longitude;
  const GeoPoint(this.latitude, this.longitude);

  @override
  bool operator ==(dynamic o) =>
      o is GeoPoint && o.latitude == latitude && o.longitude == longitude;

  @override
  int get hashCode => hashValues(latitude, longitude);
}
