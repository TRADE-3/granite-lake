import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// True for network-level failures (dropped connection, DNS blip, timeout)
/// worth a quiet retry. False for anything the server actually responded to
/// — a bad status code or a GraphQL `errors` payload means the request was
/// received and rejected, so retrying it would just repeat the failure.
///
/// This is the type-based, strictly-more-precise sibling of
/// [looksLikeTransientNetworkFailure] below — prefer this one whenever the
/// actual caught [Object] is available, since it doesn't depend on error
/// messages happening to contain a recognizable keyword.
bool isTransientNetworkError(Object error) {
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;
}

/// String-based fallback for call sites that only have a failure-reason
/// message (e.g. from a non-throwing result object) rather than the
/// original caught error — so [isTransientNetworkError] can't be applied
/// directly. Kept in the same file as, and intentionally aligned with,
/// [isTransientNetworkError] so "is this the network's fault" answers the
/// same way regardless of which form of failure a given call site has to
/// work with.
bool looksLikeTransientNetworkFailure(String? failureReason) {
  final reason = (failureReason ?? '').trim().toLowerCase();
  if (reason.isEmpty) {
    return false;
  }
  return reason.contains('event not found') ||
      reason.contains('transaction block not found') ||
      reason.contains('not found for digest') ||
      reason.contains('not indexed') ||
      reason.contains('temporar') ||
      reason.contains('timeout') ||
      reason.contains('socket') ||
      reason.contains('network');
}

/// True for a Sui object-version race: a transaction referenced a gas coin
/// (or other input object) at a version that's already stale by the time it
/// reaches consensus, because the wallet just spent that same coin in a
/// transaction submitted moments earlier and the indexer a fresh query
/// reads from hasn't caught up yet. Not the crew's fault, not a real
/// rejection, and not permanent — the same coin reads correctly again once
/// the indexer settles, typically within seconds. Treated the same as a
/// transient network failure: worth an unbounded, periodically-retried
/// queue entry rather than a terminal failure.
bool looksLikeObjectVersionRaceFailure(String? failureReason) {
  final reason = (failureReason ?? '').trim().toLowerCase();
  if (reason.isEmpty) {
    return false;
  }
  return reason.contains('needs to be rebuilt') ||
      (reason.contains('transaction') &&
          reason.contains('object') &&
          reason.contains('version'));
}
