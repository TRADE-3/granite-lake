import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'trade3_token_store.dart';

String _stringId(Object? value) => value == null ? '' : value.toString().trim();

List<T> _mapList<T>(Object? value, T Function(Map<String, dynamic>) fromJson) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final item in value)
      if (item is Map) fromJson(Map<String, dynamic>.from(item)),
  ];
}

Map<String, dynamic>? _dataNode(Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is Map<String, dynamic>) {
    return data;
  }
  if (data is Map) {
    return Map<String, dynamic>.from(data);
  }
  return null;
}

String? _readString(Map<String, dynamic> payload, List<String> keys) {
  for (final key in keys) {
    final value = payload[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}

/// A document listed under a payment schedule in the Trade3 hierarchy
/// (EP-03 response).
class Trade3HierarchyDocument {
  const Trade3HierarchyDocument({
    required this.id,
    required this.fileName,
    required this.documentType,
    required this.status,
    required this.isRequired,
  });

  factory Trade3HierarchyDocument.fromJson(Map<String, dynamic> json) {
    return Trade3HierarchyDocument(
      id: _stringId(json['id']),
      fileName: (json['file_name'] as String? ?? '').trim(),
      documentType: (json['document_type'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      isRequired: json['is_required'] == true,
    );
  }

  final String id;
  final String fileName;
  final String documentType;
  final String status;
  final bool isRequired;

  Map<String, dynamic> toJson() => {
    'id': id,
    'file_name': fileName,
    'document_type': documentType,
    'status': status,
    'is_required': isRequired,
  };
}

/// The target of a Granite capture upload: a payment schedule inside a
/// transaction, chosen via the hierarchy explorer.
class Trade3PaymentSchedule {
  const Trade3PaymentSchedule({
    required this.id,
    required this.title,
    required this.status,
    required this.documents,
  });

  factory Trade3PaymentSchedule.fromJson(Map<String, dynamic> json) {
    return Trade3PaymentSchedule(
      id: _stringId(json['id']),
      title: (json['title'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      documents: _mapList(json['documents'], Trade3HierarchyDocument.fromJson),
    );
  }

  final String id;
  final String title;
  final String status;
  final List<Trade3HierarchyDocument> documents;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'status': status,
    'documents': [for (final d in documents) d.toJson()],
  };
}

class Trade3Transaction {
  const Trade3Transaction({
    required this.id,
    required this.title,
    required this.status,
    required this.paymentSchedules,
  });

  factory Trade3Transaction.fromJson(Map<String, dynamic> json) {
    return Trade3Transaction(
      id: _stringId(json['id']),
      title: (json['title'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      paymentSchedules: _mapList(
        json['payment_schedules'],
        Trade3PaymentSchedule.fromJson,
      ),
    );
  }

  final String id;
  final String title;
  final String status;
  final List<Trade3PaymentSchedule> paymentSchedules;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'status': status,
    'payment_schedules': [for (final s in paymentSchedules) s.toJson()],
  };
}

class Trade3MasterContract {
  const Trade3MasterContract({
    required this.id,
    required this.title,
    required this.reference,
    required this.status,
    required this.transactions,
  });

  factory Trade3MasterContract.fromJson(Map<String, dynamic> json) {
    return Trade3MasterContract(
      id: _stringId(json['id']),
      title: (json['title'] as String? ?? '').trim(),
      reference: (json['reference'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      transactions: _mapList(json['transactions'], Trade3Transaction.fromJson),
    );
  }

  final String id;
  final String title;
  final String reference;
  final String status;
  final List<Trade3Transaction> transactions;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'reference': reference,
    'status': status,
    'transactions': [for (final t in transactions) t.toJson()],
  };

  /// Parses a list previously written with [toJson].
  static List<Trade3MasterContract> listFromJson(Object? value) =>
      _mapList(value, Trade3MasterContract.fromJson);
}

/// One file in an EP-04 pin request, as raw bytes.
class Trade3UploadFile {
  const Trade3UploadFile({required this.filename, required this.bytes});

  final String filename;
  final List<int> bytes;
}

/// One pinned document from the EP-04 response.
class Trade3PinnedDocument {
  const Trade3PinnedDocument({
    required this.id,
    required this.paymentScheduleId,
    required this.fileName,
    required this.fileType,
    required this.documentType,
    required this.status,
    required this.ipfsCid,
    required this.documentHash,
    required this.isVerifiedByGranite,
    required this.isGlobalDocument,
    required this.isRequired,
    this.createdAt,
  });

  factory Trade3PinnedDocument.fromJson(Map<String, dynamic> json) {
    return Trade3PinnedDocument(
      id: _stringId(json['id']),
      paymentScheduleId: _stringId(json['payment_schedule_id']),
      fileName: (json['file_name'] as String? ?? '').trim(),
      fileType: (json['file_type'] as String? ?? '').trim(),
      documentType: (json['document_type'] as String? ?? '').trim(),
      status: (json['status'] as String? ?? '').trim(),
      ipfsCid: (json['ipfs_cid'] as String? ?? '').trim(),
      documentHash: (json['document_hash'] as String? ?? '').trim(),
      isVerifiedByGranite: json['is_verified_by_granite'] == true,
      isGlobalDocument: json['is_global_document'] == true,
      isRequired: json['is_required'] == true,
      createdAt: json['created_at'] as String?,
    );
  }

  final String id;
  final String paymentScheduleId;
  final String fileName;
  final String fileType;
  final String documentType;
  final String status;
  final String ipfsCid;
  final String documentHash;
  final bool isVerifiedByGranite;
  final bool isGlobalDocument;
  final bool isRequired;
  final String? createdAt;
}

class Trade3ApiException implements Exception {
  const Trade3ApiException({
    required this.userMessage,
    required this.rawMessage,
    this.statusCode,
  });

  final String userMessage;
  final String rawMessage;
  final int? statusCode;

  @override
  String toString() => 'Trade3ApiException: $rawMessage';
}

/// The paired Trade3 session is gone (no stored tokens, or the backend
/// rejected a refresh). Callers treat this as "back to unpaired" — clear any
/// cached pairing state and route the user to pairing again.
class Trade3UnauthenticatedException extends Trade3ApiException {
  const Trade3UnauthenticatedException({
    required super.userMessage,
    required super.rawMessage,
    super.statusCode,
  });
}

/// Client for the Trade3 backend (design/mobile_integration.md, EP-01..EP-05):
/// account pairing, token refresh, hierarchy sync, document pinning, and
/// logout.
class Trade3ApiService {
  Trade3ApiService({http.Client? httpClient, Trade3TokenStore? tokenStore})
    : _httpClient = httpClient ?? http.Client(),
      _tokenStore = tokenStore ?? Trade3TokenStore();

  // Endpoint paths per design/mobile_integration.md (confirmed contract,
  // EP-01..EP-05).
  static const String _consumePairingCodePath = 'api/auth/pairing/consume';
  static const String _refreshTokenPath = 'api/auth/refresh';
  static const String _hierarchyPath = 'api/granite/sync/hierarchy';
  static const String _pinDocumentsPath = 'api/granite/pin/bonus';
  static const String _logoutPath = 'api/auth/logout';

  /// EP-04 accepts 1-10 files per request; larger uploads are chunked.
  static const int _maxFilesPerPinRequest = 10;

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json; charset=utf-8',
  };

  final http.Client _httpClient;
  final Trade3TokenStore _tokenStore;

  Future<Trade3Tokens>? _refreshInFlight;

  /// Builds an endpoint URI against [AppConstants.trade3ApiUrl].
  static Uri endpointUri(String path) {
    final base = AppConstants.trade3ApiUrl;
    final normalizedBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$normalizedBase$normalizedPath');
  }

  /// EP-01: exchanges a UUID pairing code (from the granite.trade3.io deep
  /// link or manual entry) for session tokens, and stores them on the device.
  /// [deviceId] is an optional device identifier the backend tags the
  /// session with; callers pass the local wallet address.
  Future<Trade3Tokens> pairWithCode(String code, {String? deviceId}) async {
    final normalizedCode = code.trim();
    if (normalizedCode.isEmpty) {
      throw const Trade3ApiException(
        userMessage: 'Enter the pairing code from your Trade3 profile.',
        rawMessage: 'Pairing code is empty.',
      );
    }
    final normalizedDeviceId = deviceId?.trim() ?? '';

    try {
      final response = await _httpClient.post(
        endpointUri(_consumePairingCodePath),
        headers: _jsonHeaders,
        body: jsonEncode({
          'pairing_code': normalizedCode,
          if (normalizedDeviceId.isNotEmpty) 'device_id': normalizedDeviceId,
        }),
      );
      final payload = _decodeJsonBody(response.body);
      if (!_isSuccess(response.statusCode)) {
        throw _apiFailure(
          payload,
          response.statusCode,
          'Pairing failed. Check the code and try again.',
        );
      }
      final tokens = _parseTokens(payload);
      await _tokenStore.save(tokens);
      return tokens;
    } on Trade3ApiException {
      rethrow;
    } on FormatException catch (error) {
      throw _unexpectedResponse('pairing', error);
    } catch (error) {
      throw _networkFailure('pairing', error);
    }
  }

  /// EP-03: the user's Master Contract → Transaction → Payment Schedule tree.
  Future<List<Trade3MasterContract>> syncHierarchy() async {
    try {
      final response = await _sendAuthorized(
        (accessToken) =>
            http.Request('GET', endpointUri(_hierarchyPath))
              ..headers['Authorization'] = 'Bearer $accessToken',
      );
      final payload = await _readJsonPayload(response);
      if (!_isSuccess(response.statusCode)) {
        throw _apiFailure(
          payload,
          response.statusCode,
          "Couldn't load your Trade3 projects. Try again in a moment.",
        );
      }
      return _parseHierarchy(payload);
    } on Trade3ApiException {
      rethrow;
    } on FormatException catch (error) {
      throw _unexpectedResponse('hierarchy sync', error);
    } catch (error) {
      throw _networkFailure('hierarchy sync', error);
    }
  }

  /// EP-04: uploads files to the chosen payment schedule after their Sui
  /// attestation. Requests of more than [_maxFilesPerPinRequest] files are
  /// split into multiple requests; if one chunk fails, earlier chunks stay
  /// pinned server-side and the error propagates.
  Future<List<Trade3PinnedDocument>> uploadDocuments({
    required String transactionId,
    required String paymentScheduleId,
    required List<Trade3UploadFile> files,
  }) async {
    if (files.isEmpty) {
      throw const Trade3ApiException(
        userMessage: 'Select at least one file to upload.',
        rawMessage: 'EP-04 requires at least one file.',
      );
    }

    final pinned = <Trade3PinnedDocument>[];
    for (var start = 0; start < files.length; start += _maxFilesPerPinRequest) {
      final chunk = files
          .skip(start)
          .take(_maxFilesPerPinRequest)
          .toList(growable: false);
      pinned.addAll(
        await _pinDocuments(
          transactionId: transactionId,
          paymentScheduleId: paymentScheduleId,
          files: chunk,
        ),
      );
    }
    return pinned;
  }

  Future<List<Trade3PinnedDocument>> _pinDocuments({
    required String transactionId,
    required String paymentScheduleId,
    required List<Trade3UploadFile> files,
  }) async {
    try {
      final response = await _sendAuthorized((accessToken) {
        final request =
            http.MultipartRequest('POST', endpointUri(_pinDocumentsPath))
              ..fields['transaction_id'] = transactionId
              ..fields['payment_schedule_id'] = paymentScheduleId
              ..headers['Authorization'] = 'Bearer $accessToken';
        for (final file in files) {
          request.files.add(
            http.MultipartFile.fromBytes(
              'documents',
              file.bytes,
              filename: file.filename,
            ),
          );
        }
        return request;
      });
      final payload = await _readJsonPayload(response);
      if (!_isSuccess(response.statusCode)) {
        throw _apiFailure(
          payload,
          response.statusCode,
          'The upload to Trade3 failed. Try again in a moment.',
        );
      }
      return _parsePinnedDocuments(payload);
    } on Trade3ApiException {
      rethrow;
    } on FormatException catch (error) {
      throw _unexpectedResponse('document upload', error);
    } catch (error) {
      throw _networkFailure('document upload', error);
    }
  }

  /// EP-05: invalidates the session server-side, then clears the local tokens.
  /// A session that is already dead server-side is treated the same way
  /// (tokens cleared, [Trade3UnauthenticatedException] rethrown); transient
  /// network failures keep the tokens so the user can retry.
  Future<void> disconnect() async {
    try {
      final response = await _sendAuthorized((accessToken) {
        // EP-05 posts JSON per the contract; no body fields are defined.
        final request = http.Request('POST', endpointUri(_logoutPath))
          ..headers['Authorization'] = 'Bearer $accessToken';
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(const <String, dynamic>{});
        return request;
      });
      final payload = await _readJsonPayload(response);
      if (!_isSuccess(response.statusCode)) {
        throw _apiFailure(
          payload,
          response.statusCode,
          "Couldn't unlink your Trade3 account. Try again in a moment.",
        );
      }
      await _tokenStore.clear();
    } on Trade3UnauthenticatedException {
      // The session is already invalid server-side; unlink locally as well.
      await _tokenStore.clear();
      rethrow;
    } on Trade3ApiException {
      rethrow;
    } on FormatException catch (error) {
      throw _unexpectedResponse('unlinking', error);
    } catch (error) {
      throw _networkFailure('unlinking', error);
    }
  }

  /// Runs a request with the stored access token, refreshing (single-flight)
  /// and retrying once when it comes back 401. A 401 that survives the
  /// refresh clears the tokens — the paired session is dead.
  Future<http.StreamedResponse> _sendAuthorized(
    http.BaseRequest Function(String accessToken) buildRequest,
  ) async {
    var tokens = await _tokenStore.read();
    if (tokens == null) {
      throw const Trade3UnauthenticatedException(
        userMessage: 'Link your Trade3 account before using this.',
        rawMessage: 'No stored Trade3 tokens.',
      );
    }

    var response = await _httpClient.send(buildRequest(tokens.accessToken));
    if (response.statusCode != 401) {
      return response;
    }

    tokens = await _refreshTokens();
    response = await _httpClient.send(buildRequest(tokens.accessToken));
    if (response.statusCode == 401) {
      await _tokenStore.clear();
      throw const Trade3UnauthenticatedException(
        userMessage: 'Your Trade3 session has ended. Pair your account again.',
        rawMessage: 'Access token rejected after a successful refresh.',
      );
    }
    return response;
  }

  Future<Trade3Tokens> _refreshTokens() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _performTokenRefresh().whenComplete(
      () => _refreshInFlight = null,
    );
    _refreshInFlight = future;
    return future;
  }

  Future<Trade3Tokens> _performTokenRefresh() async {
    final current = await _tokenStore.read();
    final refreshToken = current?.refreshToken ?? '';
    if (refreshToken.isEmpty) {
      await _tokenStore.clear();
      throw const Trade3UnauthenticatedException(
        userMessage: 'Link your Trade3 account before using this.',
        rawMessage: 'No refresh token to refresh with.',
      );
    }

    // EP-02 authenticates via the refresh_token in the JSON body only - no
    // Authorization header (design/mobile_integration.md).
    final response = await _httpClient.post(
      endpointUri(_refreshTokenPath),
      headers: _jsonHeaders,
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    if (!_isSuccess(response.statusCode)) {
      await _tokenStore.clear();
      throw Trade3UnauthenticatedException(
        userMessage: 'Your Trade3 session has ended. Pair your account again.',
        rawMessage: 'Token refresh rejected (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }

    final tokens = _parseTokens(_decodeJsonBody(response.body));
    await _tokenStore.save(tokens);
    return tokens;
  }

  Trade3Tokens _parseTokens(Map<String, dynamic> payload) {
    var accessToken = _readString(payload, const [
      'access_token',
      'accessToken',
    ]);
    var refreshToken = _readString(payload, const [
      'refresh_token',
      'refreshToken',
    ]);
    if (accessToken == null || refreshToken == null) {
      final data = _dataNode(payload);
      if (data != null) {
        accessToken ??= _readString(data, const [
          'access_token',
          'accessToken',
        ]);
        refreshToken ??= _readString(data, const [
          'refresh_token',
          'refreshToken',
        ]);
      }
    }
    if (accessToken == null || refreshToken == null) {
      throw const FormatException(
        'Trade3 auth response is missing access_token or refresh_token.',
      );
    }
    return Trade3Tokens(accessToken: accessToken, refreshToken: refreshToken);
  }

  List<Trade3MasterContract> _parseHierarchy(Map<String, dynamic> payload) {
    var contractsNode = payload['master_contracts'];
    if (contractsNode is! List) {
      contractsNode = _dataNode(payload)?['master_contracts'];
    }
    return _mapList(contractsNode, Trade3MasterContract.fromJson);
  }

  List<Trade3PinnedDocument> _parsePinnedDocuments(
    Map<String, dynamic> payload,
  ) {
    var documentsNode = payload['documents'];
    if (documentsNode is! List) {
      documentsNode = _dataNode(payload)?['documents'];
    }
    if (documentsNode is! List) {
      throw const FormatException(
        'Trade3 pin response is missing the documents list.',
      );
    }
    return _mapList(documentsNode, Trade3PinnedDocument.fromJson);
  }

  static bool _isSuccess(int statusCode) =>
      statusCode >= 200 && statusCode < 300;

  static Trade3ApiException _apiFailure(
    Map<String, dynamic> payload,
    int statusCode,
    String fallbackMessage,
  ) {
    final message =
        _readString(payload, const ['message', 'error']) ?? fallbackMessage;
    return Trade3ApiException(
      userMessage: message,
      rawMessage: message,
      statusCode: statusCode,
    );
  }

  static Trade3ApiException _networkFailure(String operation, Object error) {
    return Trade3ApiException(
      userMessage:
          "Couldn't reach the Trade3 service. Check your internet "
          'connection and try again.',
      rawMessage: 'Trade3 $operation request failed: $error',
    );
  }

  static Trade3ApiException _unexpectedResponse(
    String operation,
    FormatException error,
  ) {
    return Trade3ApiException(
      userMessage: 'The Trade3 service returned an unexpected response.',
      rawMessage: 'Trade3 $operation response was malformed: $error',
    );
  }

  static Map<String, dynamic> _decodeJsonBody(String rawBody) {
    if (rawBody.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(rawBody);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('Trade3 response body was not a JSON object.');
  }

  static Future<Map<String, dynamic>> _readJsonPayload(
    http.StreamedResponse response,
  ) async {
    return _decodeJsonBody(await response.stream.bytesToString());
  }
}
