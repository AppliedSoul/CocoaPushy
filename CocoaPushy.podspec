Pod::Spec.new do |spec|
  spec.name = "CocoaPushy"
  spec.version = "0.1.0"
  spec.summary = "Apple Push Notification client library with MQTT benefits"
  spec.homepage = "https://github.com/AppliedSoul/CocoaPushy"
  spec.license = { type: 'MIT', file: 'LICENSE' }
  spec.authors = { "Noel Gaur" => 'noel.gaur@qq.com' }
  spec.social_media_url = "http://facebook.com/noelgaur"

  spec.platform = :ios, "9.3"
  spec.requires_arc = true
  spec.source = { git: "https://github.com/AppliedSoul/CocoaPushy.git", tag: "v#{spec.version}", submodules: true }
  spec.source_files = "CocoaPushy/**/*.{h,swift}"

  spec.dependency "CocoaAsyncSocket", "~> 7.5.1"
  spec.dependency "MSWeakTimer", "~> 1.1.0"
  spec.dependency "CocoaMQTT", "~> 1.0.11"
end
