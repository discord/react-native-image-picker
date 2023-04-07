#import "ImagePickerManager.h"
#import "ImagePickerUtils.h"
#import <React/RCTConvert.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>

@import MobileCoreServices;

@interface ImagePickerManager ()

@property (nonatomic, strong) RCTResponseSenderBlock callback;
@property (nonatomic, copy) NSDictionary *options;

@end

@interface ImagePickerManager (UIImagePickerControllerDelegate) <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@interface ImagePickerManager (UIAdaptivePresentationControllerDelegate) <UIAdaptivePresentationControllerDelegate>
@end

@implementation ImagePickerManager

NSString *errCameraUnavailable = @"camera_unavailable";
NSString *errPermission = @"permission";
NSString *errOthers = @"others";
RNImagePickerTarget target;

photoSelected = NO;

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(launchCamera:(NSDictionary *)options callback:(RCTResponseSenderBlock)callback)
{
    target = camera;
    photoSelected = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self launchImagePicker:options callback:callback];
    });
}

RCT_EXPORT_METHOD(launchImageLibrary:(NSDictionary *)options callback:(RCTResponseSenderBlock)callback)
{
    target = library;
    photoSelected = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self launchImagePicker:options callback:callback];
    });
}

- (void)launchImagePicker:(NSDictionary *)options callback:(RCTResponseSenderBlock)callback
{
    self.callback = callback;
    
    if (target == camera && [ImagePickerUtils isSimulator]) {
        self.callback(@[@{@"errorCode": errCameraUnavailable}]);
        return;
    }
    
    self.options = options;
    
#if __has_include(<PhotosUI/PHPicker.h>)
    if([self.options[@"useNewIOSPicker"] boolValue]) {
        if (@available(iOS 14, *)) {
            if (target == library) {
                PHPickerConfiguration *configuration = [ImagePickerUtils makeConfigurationFromOptions:options target:target];
                PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
                picker.delegate = self;
                picker.modalPresentationStyle = [ImagePickerUtils getPresentationStyle:options[@"presentationStyle"]];
                picker.presentationController.delegate = self;
                
                if([self.options[@"includeExtra"] boolValue]) {
                    
                    [self checkPhotosPermissions:^(BOOL granted) {
                        if (!granted) {
                            self.callback(@[@{@"errorCode": errPermission}]);
                            return;
                        }
                        [self showPickerViewController:picker];
                    }];
                } else {
                    [self showPickerViewController:picker];
                }
                
                return;
            }
        }
    }
#endif
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    [ImagePickerUtils setupPickerFromOptions:picker options:self.options target:target];
    picker.delegate = self;
    
    if([self.options[@"includeExtra"] boolValue]) {
        [self checkPhotosPermissions:^(BOOL granted) {
            if (!granted) {
                self.callback(@[@{@"errorCode": errPermission}]);
                return;
            }
            [self showPickerViewController:picker];
        }];
    } else {
      [self showPickerViewController:picker];
    }
}

- (void) showPickerViewController:(UIViewController *)picker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = RCTPresentedViewController();
        [root presentViewController:picker animated:YES completion:nil];
    });
}

#pragma mark - Helpers

NSData* extractImageData(UIImage* image){
    CFMutableDataRef imageData = CFDataCreateMutable(NULL, 0);
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(imageData, kUTTypeJPEG, 1, NULL);
    
    CFStringRef orientationKey[1];
    CFTypeRef   orientationValue[1];
    CGImagePropertyOrientation CGOrientation = CGImagePropertyOrientationForUIImageOrientation(image.imageOrientation);

    orientationKey[0] = kCGImagePropertyOrientation;
    orientationValue[0] = CFNumberCreate(NULL, kCFNumberIntType, &CGOrientation);

    CFDictionaryRef imageProps = CFDictionaryCreate( NULL, (const void **)orientationKey, (const void **)orientationValue, 1,
                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    CGImageDestinationAddImage(destination, image.CGImage, imageProps);
    
    CGImageDestinationFinalize(destination);
    
    CFRelease(destination);
    CFRelease(orientationValue[0]);
    CFRelease(imageProps);
    return (__bridge NSData *)imageData;
}

-(NSMutableDictionary *)mapImageToAsset:(UIImage *)image data:(NSData *)data phAsset:(PHAsset * _Nullable)phAsset {
    NSString *fileType = [ImagePickerUtils getFileType:data];
    NSMutableDictionary *asset = [[NSMutableDictionary alloc] init];
    
    if (target == camera) {
        if ([self.options[@"saveToPhotos"] boolValue]) {
            __block PHObjectPlaceholder *placeholder;
            NSError *error = nil;
            [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
                PHAssetChangeRequest *assetRequest = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
                placeholder = [assetRequest placeholderForCreatedAsset];
            } error:&error];
            // Don't fail the entire process on photo library error, because we still
            // have the successful temporary filepath to work with.
            if (error == nil) {
                asset[@"id"] = [placeholder localIdentifier];
                if ([self.options[@"skipProcessing"] boolValue]) {
                    PHFetchResult* fetchResult =
                      [PHAsset fetchAssetsWithLocalIdentifiers:@[ [placeholder localIdentifier] ] options:nil];
                    PHAsset* phAsset = fetchResult.firstObject;
                    return [self mapPHAssetImageToAsset:phAsset];
                }
            }
        }
        data = extractImageData(image);
    }
    
    if (data == nil) {
        data = extractImageData(image);
    }
    
    UIImage* newImage = image;
    if (![fileType isEqualToString:@"gif"]) {
        newImage = [ImagePickerUtils resizeImage:image
                                     maxWidth:[self.options[@"maxWidth"] floatValue]
                                    maxHeight:[self.options[@"maxHeight"] floatValue]];
    }

    float quality = [self.options[@"quality"] floatValue];
    if (![image isEqual:newImage] || (quality >= 0 && quality < 1)) {
        if ([fileType isEqualToString:@"jpg"]) {
            data = UIImageJPEGRepresentation(newImage, quality);
        }
        else if ([fileType isEqualToString:@"png"]) {
            data = UIImagePNGRepresentation(newImage);
        }
    }
    
    asset[@"type"] = [@"image/" stringByAppendingString:fileType];

    NSString *fileName = [self getImageFileName:fileType];
    NSString *path = [[NSTemporaryDirectory() stringByStandardizingPath] stringByAppendingPathComponent:fileName];
    [data writeToFile:path atomically:YES];

    if ([self.options[@"includeBase64"] boolValue]) {
        asset[@"base64"] = [data base64EncodedStringWithOptions:0];
    }

    NSURL *fileURL = [NSURL fileURLWithPath:path];
    asset[@"uri"] = [fileURL absoluteString];

    NSNumber *fileSizeValue = nil;
    NSError *fileSizeError = nil;
    [fileURL getResourceValue:&fileSizeValue forKey:NSURLFileSizeKey error:&fileSizeError];
    if (fileSizeValue){
        asset[@"fileSize"] = fileSizeValue;
    }

    asset[@"fileName"] = fileName;
    asset[@"width"] = @(newImage.size.width);
    asset[@"height"] = @(newImage.size.height);

    if(phAsset){
        asset[@"timestamp"] = [self getDateTimeInUTC:phAsset.creationDate];
        asset[@"id"] = phAsset.localIdentifier;
        // Add more extra data here ...
    }
    
    return asset;
}

-(NSMutableDictionary *)mapPHAssetToAsset:(PHAsset*)phAsset {
    NSMutableDictionary *asset = [[NSMutableDictionary alloc] init];
    asset[@"uri"] = [NSString stringWithFormat:@"ph://%@", [phAsset localIdentifier]];
    PHAssetResource* resource = [[PHAssetResource assetResourcesForAsset:phAsset] firstObject];
    asset[@"fileSize"] = [resource valueForKey:@"fileSize"];
    asset[@"fileName"] = resource.originalFilename;
    asset[@"width"] = @(phAsset.pixelWidth);
    asset[@"height"] = @(phAsset.pixelHeight);
    asset[@"timestamp"] = [self getDateTimeInUTC:phAsset.creationDate];
    asset[@"id"] = phAsset.localIdentifier;
    return asset;
}

-(NSMutableDictionary *)mapPHAssetImageToAsset:(PHAsset*)phAsset {
    NSMutableDictionary *asset = [self mapPHAssetToAsset:phAsset];
    asset[@"fileType"] = @"image";
    return asset;
}

-(NSMutableDictionary *)mapPHAssetVideoToAsset:(PHAsset*)phAsset {
    NSMutableDictionary *asset = [self mapPHAssetToAsset:phAsset];
    asset[@"fileType"] = @"video";
    return asset;
}

CGImagePropertyOrientation CGImagePropertyOrientationForUIImageOrientation(
  UIImageOrientation uiOrientation)
{
    // code from here:
    // https://developer.apple.com/documentation/imageio/cgimagepropertyorientation?language=objc
    switch (uiOrientation) {
    case UIImageOrientationUp:
        return kCGImagePropertyOrientationUp;
    case UIImageOrientationDown:
        return kCGImagePropertyOrientationDown;
    case UIImageOrientationLeft:
        return kCGImagePropertyOrientationLeft;
    case UIImageOrientationRight:
        return kCGImagePropertyOrientationRight;
    case UIImageOrientationUpMirrored:
        return kCGImagePropertyOrientationUpMirrored;
    case UIImageOrientationDownMirrored:
        return kCGImagePropertyOrientationDownMirrored;
    case UIImageOrientationLeftMirrored:
        return kCGImagePropertyOrientationLeftMirrored;
    case UIImageOrientationRightMirrored:
        return kCGImagePropertyOrientationRightMirrored;
    }
}

-(NSMutableDictionary *)mapVideoToAsset:(NSURL *)url phAsset:(PHAsset * _Nullable)phAsset error:(NSError **)error {
    NSString *fileName = [url lastPathComponent];
    NSString *path = [[NSTemporaryDirectory() stringByStandardizingPath] stringByAppendingPathComponent:fileName];
    NSURL *videoDestinationURL = [NSURL fileURLWithPath:path];
    NSMutableDictionary *asset = [[NSMutableDictionary alloc] init];
    
    if ((target == camera) && [self.options[@"saveToPhotos"] boolValue]) {
        __block PHObjectPlaceholder *placeholder;
        NSError *error = nil;
        [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
            PHAssetChangeRequest *assetRequest = [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
            placeholder = [assetRequest placeholderForCreatedAsset];
        } error:&error];
        // Don't fail the entire process on photo library error, because we still
        // have the successful temporary filepath to work with.
        if (error == nil) {
            asset[@"id"] = [placeholder localIdentifier];
            if ([self.options[@"skipProcessing"] boolValue]) {
                PHFetchResult* fetchResult =
                  [PHAsset fetchAssetsWithLocalIdentifiers:@[ [placeholder localIdentifier] ] options:nil];
                PHAsset* phAsset = fetchResult.firstObject;
                return [self mapPHAssetVideoToAsset:phAsset];
            }
        }
    }
    
    if (![url.URLByResolvingSymlinksInPath.path isEqualToString:videoDestinationURL.URLByResolvingSymlinksInPath.path]) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        
        // Delete file if it already exists
        if ([fileManager fileExistsAtPath:videoDestinationURL.path]) {
            [fileManager removeItemAtURL:videoDestinationURL error:nil];
        }

        if (url) { // Protect against reported crash

          // If we have write access to the source file, move it. Otherwise use copy.
          if ([fileManager isWritableFileAtPath:[url path]]) {
            [fileManager moveItemAtURL:url toURL:videoDestinationURL error:error];
          } else {
            [fileManager copyItemAtURL:url toURL:videoDestinationURL error:error];
          }

          if (error && *error) {
              return nil;
          }
        }
    }

    CGSize dimentions = [ImagePickerUtils getVideoDimensionsFromUrl:videoDestinationURL];
    asset[@"fileName"] = fileName;
    asset[@"duration"] = [NSNumber numberWithDouble:CMTimeGetSeconds([AVAsset assetWithURL:videoDestinationURL].duration)];
    asset[@"uri"] = videoDestinationURL.absoluteString;
    asset[@"type"] = [ImagePickerUtils getFileTypeFromUrl:videoDestinationURL];
    asset[@"fileSize"] = [ImagePickerUtils getFileSizeFromUrl:videoDestinationURL];
    asset[@"width"] = @(dimentions.width);
    asset[@"height"] = @(dimentions.height);

    if(phAsset){
        asset[@"timestamp"] = [self getDateTimeInUTC:phAsset.creationDate];
        asset[@"id"] = phAsset.localIdentifier;
        // Add more extra data here ...
    }

    return asset;
}

- (NSString *) getDateTimeInUTC:(NSDate *)date {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSZ"];
    return [formatter stringFromDate:date];
}

- (void)checkCameraPermissions:(void(^)(BOOL granted))callback
{
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        callback(YES);
        return;
    }
    else if (status == AVAuthorizationStatusNotDetermined){
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            callback(granted);
            return;
        }];
    }
    else {
        callback(NO);
    }
}

- (void)checkPhotosPermissions:(void(^)(BOOL granted))callback
{
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized) {
        callback(YES);
        return;
    } else if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                callback(YES);
                return;
            }
            else {
                callback(NO);
                return;
            }
        }];
    }
    else {
        callback(NO);
    }
}

// Both camera and photo write permission is required to take picture/video and store it to public photos
- (void)checkCameraAndPhotoPermission:(void(^)(BOOL granted))callback
{
    [self checkCameraPermissions:^(BOOL cameraGranted) {
        if (!cameraGranted) {
            callback(NO);
            return;
        }

        [self checkPhotosPermissions:^(BOOL photoGranted) {
            if (!photoGranted) {
                callback(NO);
                return;
            }
            callback(YES);
        }];
    }];
}

- (void)checkPermission:(void(^)(BOOL granted)) callback
{
    void (^permissionBlock)(BOOL) = ^(BOOL permissionGranted) {
        if (!permissionGranted) {
            callback(NO);
            return;
        }
        callback(YES);
    };

    if (target == camera && [self.options[@"saveToPhotos"] boolValue]) {
        [self checkCameraAndPhotoPermission:permissionBlock];
    }
    else if (target == camera) {
        [self checkCameraPermissions:permissionBlock];
    }
    else {
        if (@available(iOS 11.0, *)) {
            callback(YES);
        }
        else {
            [self checkPhotosPermissions:permissionBlock];
        }
    }
}

- (NSString *)getImageFileName:(NSString *)fileType
{
    NSString *fileName = [[NSUUID UUID] UUIDString];
    fileName = [fileName stringByAppendingString:@"."];
    return [fileName stringByAppendingString:fileType];
}

+ (UIImage *)getUIImageFromInfo:(NSDictionary *)info
{
    UIImage *image = info[UIImagePickerControllerEditedImage];
    if (!image) {
        image = info[UIImagePickerControllerOriginalImage];
    }
    return image;
}

+ (NSURL *)getNSURLFromInfo:(NSDictionary *)info {
    if (@available(iOS 11.0, *)) {
        return info[UIImagePickerControllerImageURL];
    }
    else {
        return info[UIImagePickerControllerReferenceURL];
    }
}

@end

@implementation ImagePickerManager (UIImagePickerControllerDelegate)

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info
{
    dispatch_block_t dismissCompletionBlock = ^{
        NSMutableArray<NSDictionary *> *assets = [[NSMutableArray alloc] initWithCapacity:1];
        PHAsset *asset = nil;
        
        if (photoSelected == YES) {
            return;
        }
        photoSelected = YES;

        // If include extra, we fetch the PHAsset, this required library permissions
        if([self.options[@"includeExtra"] boolValue]) {
            asset = [ImagePickerUtils fetchPHAssetOnIOS13:info];
        }

        if ([info[UIImagePickerControllerMediaType] isEqualToString:(NSString *) kUTTypeImage]) {
            UIImage *image = [ImagePickerManager getUIImageFromInfo:info];
            
            [assets addObject:[self mapImageToAsset:image data:[NSData dataWithContentsOfURL:[ImagePickerManager getNSURLFromInfo:info]] phAsset:asset]];
        } else {
            NSError *error;
            NSDictionary *videoAsset = [self mapVideoToAsset:info[UIImagePickerControllerMediaURL] phAsset:asset error:&error];
                        
            if (videoAsset == nil) {
                NSString *errorMessage = error.localizedFailureReason;
                if (errorMessage == nil) errorMessage = @"Video asset not found";
                self.callback(@[@{@"errorCode": errOthers, @"errorMessage": errorMessage}]);
                return;
            }
            [assets addObject:videoAsset];
        }

        NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
        response[@"assets"] = assets;
        if (@available(iOS 15, *)) {
            response[@"replaceSelection"] = @(YES);
        }
        self.callback(@[response]);
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        [picker dismissViewControllerAnimated:YES completion:dismissCompletionBlock];
    });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [picker dismissViewControllerAnimated:YES completion:^{
            self.callback(@[@{@"didCancel": @YES}]);
        }];
    });
}

@end

@implementation ImagePickerManager (presentationControllerDidDismiss)

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController
{
    self.callback(@[@{@"didCancel": @YES}]);
}

@end

#if __has_include(<PhotosUI/PHPicker.h>)
@implementation ImagePickerManager (PHPickerViewControllerDelegate)

- (void)picker:(PHPickerViewController*)picker
  didFinishPicking:(NSArray<PHPickerResult*>*)results API_AVAILABLE(ios(14))
{
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (photoSelected == YES) {
        return;
    }
    photoSelected = YES;

    dispatch_group_t completionGroup = dispatch_group_create();
    NSMutableArray<NSDictionary*>* assets = [[NSMutableArray alloc] initWithCapacity:results.count];
    for (int i = 0; i < results.count; i++) {
        [assets addObject:(NSDictionary*)[NSNull null]];
    }

    [results enumerateObjectsUsingBlock:^(PHPickerResult* result, NSUInteger index, BOOL* stop) {
        PHAsset* asset = nil;
        NSItemProvider* provider = result.itemProvider;
        BOOL isPreselectedAsset = [provider.registeredTypeIdentifiers count] == 0;

        // If include extra, we fetch the PHAsset, this required library permissions
        if (([self.options[@"includeExtra"] boolValue] && result.assetIdentifier != nil) || isPreselectedAsset || [self.options[@"skipProcessing"] boolValue]) {
            PHFetchResult* fetchResult =
              [PHAsset fetchAssetsWithLocalIdentifiers:@[ result.assetIdentifier ] options:nil];
            asset = fetchResult.firstObject;
        }
        
        if (isPreselectedAsset && asset !=  nil) {
            // Return a bare asset with the id populate, so consumer can handle deduplication.
            NSMutableDictionary* mappedAsset = [[NSMutableDictionary alloc] init];
            mappedAsset[@"id"] = asset.localIdentifier;
            mappedAsset[@"isPreselected"] = @(YES);
            assets[index] = mappedAsset;
            return;
        }

        // It's possible that the user selected an image which is NOT shared to the application, permissions-wise.
        // In those cases, the PHAsset will be nil because it can't be fetched. Therefore, we need to fall back to
        // the raw UIImage strategy by loading data from the provider's url.
        if (asset != nil && [self.options[@"skipProcessing"] boolValue]) {
            // When the skipProcessing flag is set, we avoid expensive file-content operations by simply
            // fetching metadata via the PHAsset. As a result, this doesn't respect any of the library's
            // special data-processing configurations, such as "quality" or "includeBase64". It also omits
            // the "fileType" property in the response because that would require inspecting the file contents.
            // The returned URI for the asset is a PhotoKit "ph://" prefixed uri.
            if ([provider hasItemConformingToTypeIdentifier:(NSString *)kUTTypeImage]) {
                NSMutableDictionary* mappedAsset = [self mapPHAssetImageToAsset:asset];
                assets[index] = mappedAsset;
            } else if ([provider hasItemConformingToTypeIdentifier:(NSString*)kUTTypeMovie]) {
                NSMutableDictionary* mappedAsset = [self mapPHAssetVideoToAsset:asset];
                assets[index] = mappedAsset;
            }
        } else {
            dispatch_group_enter(completionGroup);
            
            if ([provider hasItemConformingToTypeIdentifier:(NSString *)kUTTypeImage]) {
                NSString *identifier = provider.registeredTypeIdentifiers.firstObject;
                // Matches both com.apple.live-photo-bundle and com.apple.private.live-photo-bundle
                if ([identifier containsString:@"live-photo-bundle"]) {
                    // Handle live photos
                    identifier = @"public.jpeg";
                }
                
                [provider loadFileRepresentationForTypeIdentifier:identifier completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
                    NSData *data = [[NSData alloc] initWithContentsOfURL:url];
                    UIImage *image = [[UIImage alloc] initWithData:data];
                    
                    NSMutableDictionary* mappedAsset = [self mapImageToAsset:image data:data phAsset:asset];
                    mappedAsset[@"id"] = result.assetIdentifier;
                    assets[index] = mappedAsset;
                    dispatch_group_leave(completionGroup);
                }];
            } else if ([provider hasItemConformingToTypeIdentifier:(NSString*)kUTTypeMovie]) {
                [provider
                 loadFileRepresentationForTypeIdentifier:(NSString*)kUTTypeMovie
                 completionHandler:^(NSURL* _Nullable url,
                                     NSError* _Nullable error) {
                    NSMutableDictionary* mappedAsset =
                    [self mapVideoToAsset:url phAsset:asset error:nil];
                    if (mappedAsset != nil) {
                        mappedAsset[@"id"] = result.assetIdentifier;
                        assets[index] = mappedAsset;
                    }
                    dispatch_group_leave(completionGroup);
                }];
            } else {
                // The provider didn't have an item matching photo or video (fails on M1 Mac Simulator)
                dispatch_group_leave(completionGroup);
            }
        }
    }];

    dispatch_group_notify(completionGroup, dispatch_get_main_queue(), ^{
        //  mapVideoToAsset can fail and return nil, leaving asset NSNull.
        for (NSDictionary* asset in assets) {
            if ([asset isEqual:[NSNull null]]) {
                self.callback(@[ @{@"errorCode" : errOthers} ]);
                return;
            }
        }

        NSMutableDictionary* response = [[NSMutableDictionary alloc] init];
        [response setObject:assets forKey:@"assets"];
        if (@available(iOS 15, *)) {
            response[@"replaceSelection"] = @(YES);
        }
        self.callback(@[ response ]);
    });
}

@end
#endif
