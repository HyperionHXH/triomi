@import XCTest;
@import integration_test;

/// Runs the same Dart integration tests without VM-service log discovery.
@interface IosIntegrationTests : XCTestCase
@end

@implementation IosIntegrationTests
- (void)testDartIntegrationResults {
  FLTIntegrationTestRunner *runner = [[FLTIntegrationTestRunner alloc] init];
  __block NSUInteger completed = 0;
  [runner testIntegrationTestWithResults:^(SEL selector, BOOL success, NSString *failure) {
    completed++;
    XCTAssertTrue(success, @"%@: %@", NSStringFromSelector(selector), failure);
  }];
  XCTAssertGreaterThan(completed, 0, @"The actual Dart suite must report results");
}
@end
