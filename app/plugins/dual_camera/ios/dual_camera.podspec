# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
#
# The plugin is built with Swift Package Manager (dual_camera/Package.swift);
# this podspec is kept equivalent for CocoaPods builds.
Pod::Spec.new do |s|
  s.name             = 'dual_camera'
  s.version          = '0.0.1'
  s.summary          = 'Camera control for stitchable two-phone recording.'
  s.description      = <<-DESC
AVCaptureSession + AVAssetWriter recorder with gapless segment rotation,
locked 3A, stabilization off and ultra-wide lens selection.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = 'The OpenSportsBall Authors'
  s.source           = { :path => '.' }
  s.source_files = 'dual_camera/Sources/dual_camera/**/*.swift'
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Declares the free-disk-space API (low-storage check).
  s.resource_bundles = {'dual_camera_privacy' => ['dual_camera/Sources/dual_camera/PrivacyInfo.xcprivacy']}
end
