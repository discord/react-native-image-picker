#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>
#import <React/RCTConvert.h>

typedef NS_ENUM(NSInteger, RNImagePickerTarget) {
  camera = 1,
  library
};

typedef NSString * _Nonnull (^RNImagePickerTemporaryFilePathProvider)(NSString * _Nonnull pathExtension);

@interface ImagePickerManager : NSObject <RCTBridgeModule>

// Configure before presenting a picker. Return a unique writable path for each file.
+ (void)setTemporaryFilePathProvider:(RNImagePickerTemporaryFilePathProvider _Nullable)provider;

@end
