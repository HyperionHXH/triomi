// Execute the same public protocol contracts with the production iOS WebKit runtime.
import '../test/baozimanhuaplus_js_rule_test.dart' as baozimanhuaplus;
import '../test/baozimhorg_js_rule_test.dart' as baozimhorg;
import '../test/bh3_js_rule_test.dart' as bh3;
import '../test/dongmanmanhua_js_rule_test.dart' as dongmanmanhua;
import '../test/guazimanhua_js_rule_test.dart' as guazimanhua;
import '../test/iqiyi_js_rule_test.dart' as iqiyi;
import '../test/kuaikanmanhua_js_rule_test.dart' as kuaikanmanhua;
import '../test/mh1234_js_rule_test.dart' as mh1234;
import '../test/miaoqu_js_rule_test.dart' as miaoqu;
import '../test/terrahistoricus_js_rule_test.dart' as terrahistoricus;
import '../test/zaimanhua_js_rule_test.dart' as zaimanhua;
import '../test/zazhimi_js_rule_test.dart' as zazhimi;
import 'fixtures/ios_test_binding.dart';

void main() {
  initializeIosIntegrationBinding();
  bh3.main();
  terrahistoricus.main();
  kuaikanmanhua.main();
  mh1234.main();
  guazimanhua.main();
  miaoqu.main();
  iqiyi.main();
  dongmanmanhua.main();
  baozimanhuaplus.main();
  baozimhorg.main();
  zaimanhua.main();
  zazhimi.main();
}
