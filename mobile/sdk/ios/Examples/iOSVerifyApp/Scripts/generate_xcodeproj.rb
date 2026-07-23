#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"
require "fileutils"

sample_dir = File.expand_path("..", __dir__)
project_path = File.join(sample_dir, "SenseCraftVoiceVerifyApp.xcodeproj")
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "1600"
project.root_object.attributes["LastUpgradeCheck"] = "1600"

target = project.new_target(:application, "SenseCraftVoiceVerifyApp", :ios, "16.0")
target.product_name = "SenseCraft Voice Verify"

sources_group = project.main_group.new_group("Sources", "Sources")
Dir[File.join(sample_dir, "Sources", "*.swift")].sort.each do |path|
  ref = sources_group.new_file(path)
  target.add_file_references([ref])
end

resources_group = project.main_group.new_group("Configuration")
resources_group.new_file(File.join(sample_dir, "Info.plist"))
resources_group.new_file(File.join(sample_dir, "Entitlements", "SenseCraftVoiceVerifyApp.entitlements"))

package_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_ref.relative_path = "../.."
project.root_object.package_references << package_ref

product_dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product_dependency.package = package_ref
product_dependency.product_name = "SenseCraftVoiceIOS"
target.package_product_dependencies << product_dependency

framework_build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
framework_build_file.product_ref = product_dependency
target.frameworks_build_phase.files << framework_build_file

common_settings = {
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "",
  "CODE_SIGN_ENTITLEMENTS" => "Entitlements/SenseCraftVoiceVerifyApp.entitlements",
  "CODE_SIGN_STYLE" => "Automatic",
  "CURRENT_PROJECT_VERSION" => "1",
  "DEVELOPMENT_TEAM" => "",
  "ENABLE_PREVIEWS" => "YES",
  "GENERATE_INFOPLIST_FILE" => "NO",
  "INFOPLIST_FILE" => "Info.plist",
  "IPHONEOS_DEPLOYMENT_TARGET" => "16.0",
  "MARKETING_VERSION" => "1.0",
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.seeed.sensecraftvoice.verify",
  "PRODUCT_NAME" => "SenseCraft Voice Verify",
  "SWIFT_EMIT_LOC_STRINGS" => "YES",
  "SWIFT_VERSION" => "5.9",
  "TARGETED_DEVICE_FAMILY" => "1"
}

target.build_configurations.each do |config|
  config.build_settings.merge!(common_settings)
end

project.build_configurations.each do |config|
  config.build_settings["CLANG_ANALYZER_NONNULL"] = "YES"
  config.build_settings["CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION"] = "YES_AGGRESSIVE"
  config.build_settings["CLANG_CXX_LANGUAGE_STANDARD"] = "gnu++20"
  config.build_settings["CLANG_ENABLE_MODULES"] = "YES"
  config.build_settings["CLANG_ENABLE_OBJC_ARC"] = "YES"
  config.build_settings["CLANG_ENABLE_OBJC_WEAK"] = "YES"
  config.build_settings["CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING"] = "YES"
  config.build_settings["CLANG_WARN_BOOL_CONVERSION"] = "YES"
  config.build_settings["CLANG_WARN_COMMA"] = "YES"
  config.build_settings["CLANG_WARN_CONSTANT_CONVERSION"] = "YES"
  config.build_settings["CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS"] = "YES"
  config.build_settings["CLANG_WARN_DIRECT_OBJC_ISA_USAGE"] = "YES_ERROR"
  config.build_settings["CLANG_WARN_DOCUMENTATION_COMMENTS"] = "YES"
  config.build_settings["CLANG_WARN_EMPTY_BODY"] = "YES"
  config.build_settings["CLANG_WARN_ENUM_CONVERSION"] = "YES"
  config.build_settings["CLANG_WARN_INFINITE_RECURSION"] = "YES"
  config.build_settings["CLANG_WARN_INT_CONVERSION"] = "YES"
  config.build_settings["CLANG_WARN_NON_LITERAL_NULL_CONVERSION"] = "YES"
  config.build_settings["CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF"] = "YES"
  config.build_settings["CLANG_WARN_OBJC_LITERAL_CONVERSION"] = "YES"
  config.build_settings["CLANG_WARN_OBJC_ROOT_CLASS"] = "YES_ERROR"
  config.build_settings["CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER"] = "YES"
  config.build_settings["CLANG_WARN_RANGE_LOOP_ANALYSIS"] = "YES"
  config.build_settings["CLANG_WARN_STRICT_PROTOTYPES"] = "YES"
  config.build_settings["CLANG_WARN_SUSPICIOUS_MOVE"] = "YES"
  config.build_settings["CLANG_WARN_UNGUARDED_AVAILABILITY"] = "YES_AGGRESSIVE"
  config.build_settings["CLANG_WARN_UNREACHABLE_CODE"] = "YES"
  config.build_settings["CLANG_WARN__DUPLICATE_METHOD_MATCH"] = "YES"
  config.build_settings["COPY_PHASE_STRIP"] = "NO"
  config.build_settings["ENABLE_STRICT_OBJC_MSGSEND"] = "YES"
  config.build_settings["GCC_C_LANGUAGE_STANDARD"] = "gnu17"
  config.build_settings["GCC_NO_COMMON_BLOCKS"] = "YES"
  config.build_settings["GCC_WARN_64_TO_32_BIT_CONVERSION"] = "YES"
  config.build_settings["GCC_WARN_ABOUT_RETURN_TYPE"] = "YES_ERROR"
  config.build_settings["GCC_WARN_UNDECLARED_SELECTOR"] = "YES"
  config.build_settings["GCC_WARN_UNINITIALIZED_AUTOS"] = "YES_AGGRESSIVE"
  config.build_settings["GCC_WARN_UNUSED_FUNCTION"] = "YES"
  config.build_settings["GCC_WARN_UNUSED_VARIABLE"] = "YES"
end

project.save
puts "Generated #{project_path}"
