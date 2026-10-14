platform :osx, "13.0"

source 'https://github.com/MacDownApp/cocoapods-specs.git'  # Patched libraries.
source 'https://cdn.cocoapods.org/'

project 'MacDown.xcodeproj'

inhibit_all_warnings!

target "MacDown" do
  pod 'handlebars-objc', '~> 1.4'
  pod 'hoedown', '~> 3.0.7', :inhibit_warnings => false
  pod 'JJPluralForm', '~> 2.1'
  pod 'LibYAML', '~> 0.1'
  pod 'M13OrderedDictionary', '~> 1.1'
  pod 'MASPreferences', '~> 1.3'
  pod 'Sparkle', '2.9.6', :inhibit_warnings => false

  pod 'PAPreferences', '~> 0.4'
  target "MacDownTests" do
    inherit! :search_paths
  end
end

target "macdown-cmd" do
  pod 'GBCli', '~> 1.1'
end

# Older source pods still declare deployment targets unsupported by modern Xcode.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
