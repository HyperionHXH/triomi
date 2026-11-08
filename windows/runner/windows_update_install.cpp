#include "windows_update_install.h"
#include "windows_update_common.h"
#include "windows_update_revision.h"

namespace {
const flutter::EncodableValue& Field(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  triomi_update::Require(it != map.end(), "Missing Windows update argument");
  return it->second;
}
const std::string& Text(const flutter::EncodableValue& value) {
  const auto* text = std::get_if<std::string>(&value);
  triomi_update::Require(text != nullptr, "Windows update argument must be a string");
  return *text;
}
uint64_t Integer(const flutter::EncodableValue& value) {
  int64_t n = -1;
  if (const auto* value32 = std::get_if<int32_t>(&value)) n = *value32;
  else if (const auto* value64 = std::get_if<int64_t>(&value)) n = *value64;
  triomi_update::Require(n >= 0, "Windows update member size must be a nonnegative integer");
  return static_cast<uint64_t>(n);
}
}  // namespace

void LaunchWindowsUpdate(HWND owner, const flutter::EncodableMap& args) {
  (void)owner;
  using namespace triomi_update;
  const auto* consent = std::get_if<bool>(&Field(args, "consent"));
  Require(consent && *consent, "Explicit Windows update installation consent is required");
  Require(args.size() == 3, "Unexpected Windows update arguments");
  Plan plan;
  plan.executable = Image();  // Never accept an install destination from Dart.
  plan.payload = Absolute(Wide(Text(Field(args, "payloadPath"))));
  const auto* files = std::get_if<flutter::EncodableMap>(&Field(args, "files"));
  Require(files && !files->empty() && files->size() <= kFileLimit, "Invalid Windows update manifest file count");
  plan.files.reserve(files->size());
  for (const auto& item : *files) {
    const auto* metadata = std::get_if<flutter::EncodableMap>(&item.second);
    Require(metadata && metadata->size() == 2, "Invalid Windows update member metadata");
    File file;
    file.path = Relative(Wide(Text(item.first)));
    file.size = Integer(Field(*metadata, "size"));
    file.hash = Hex(Text(Field(*metadata, "sha256")));
    plan.files.push_back(std::move(file));
  }
  Pins pins;
  pins.Directory(Parent(plan.payload), true);
  pins.Directory(plan.payload, true);
  plan.stage = Unique(Parent(plan.payload) + L"\\install-");
  ValidatePlan(plan);
  ReadInstalledRevision(plan.payload + L"\\triomi.exe");
  pins.Directory(Parent(plan.executable));
  CheckWritable(plan);
  Require(CreateDirectoryW(plan.stage.c_str(), nullptr) != FALSE, "Cannot create exclusive Windows update helper stage");
  // Keep the stage, plan and outcome for a diagnosable fixed recovery location.
  // The helper is copied from this installed app, never from downloaded payload.
  Handle parent(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, GetCurrentProcessId()));
  Require(static_cast<bool>(parent), "Cannot retain current application process for update handoff");
  auto helper = StartHelper(plan, parent.get(), Parent(plan.executable) + L"\\" + kHelperName);
}
