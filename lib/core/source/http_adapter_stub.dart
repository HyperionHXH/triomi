import 'package:dio/dio.dart';

import 'bangumi_route_policy.dart';

void configureSourceHttpAdapter(
  Dio dio, {
  String proxy = '',
  BangumiRoutePolicy bangumiRoutes = const BangumiRoutePolicy(),
  BangumiRoutePolicy Function()? bangumiRoutesResolver,
}) {}
