import 'package:http/http.dart';
import 'package:on_chain/on_chain.dart';

class SuiHttpService implements SuiServiceProvider {
  SuiHttpService(
    this.url, {
    Client? client,
    this.defaultTimeout = const Duration(seconds: 30),
  }) : _client = client ?? Client();

  final String url;
  final Client _client;
  final Duration defaultTimeout;

  @override
  Future<SuiServiceResponse<T>> doRequest<T>(
    SuiRequestDetails params, {
    Duration? timeout,
  }) async {
    final response = await _client
        .post(params.toUri(url), headers: params.headers, body: params.body())
        .timeout(timeout ?? defaultTimeout);
    return params.parseResponse(response.bodyBytes, response.statusCode);
  }
}
