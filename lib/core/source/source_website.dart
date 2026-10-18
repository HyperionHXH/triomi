/// Source homepages may be opened without exporting credentials, signed request
/// parameters or session headers. Ordinary public query/fragment navigation is
/// preserved, including explicitly configured local-network sources.
Uri publicSourceWebsiteUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      value.contains(RegExp(r'[\x00-\x20\\]'))) {
    throw const FormatException('网站地址必须是无账号信息的 HTTP(S) 地址');
  }
  final sensitive = RegExp(
    r'(^|[_\-.])(access.?token|refresh.?token|id.?token|token|auth|authorization|password|passwd|secret|credential|cookie|session|sessionid|jwt|signature|sig|api.?key|key)($|[_\-.])',
    caseSensitive: false,
  );
  // Hash routers put their query after a route, while OAuth implicit flows
  // commonly use bare fragment parameters. Parse each actual parameter form.
  final fragment = uri.fragment;
  final fragmentParameters = [
    fragment,
    if (fragment.contains('?')) fragment.substring(fragment.indexOf('?') + 1),
  ];
  if (uri.queryParameters.keys.any(sensitive.hasMatch) ||
      fragmentParameters.any(
        (parameters) =>
            Uri.tryParse('https://source.invalid/?$parameters')
                ?.queryParameters
                .keys
                .any(sensitive.hasMatch) ??
            false,
      )) {
    throw const FormatException('来源网站地址包含凭据或签名参数，不能交给浏览器');
  }
  return uri;
}
