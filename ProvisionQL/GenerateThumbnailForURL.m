#import "Shared.h"

//Layout constants
#define BADGE_MARGIN        10.0
#define MIN_BADGE_WIDTH     40.0
#define BADGE_HEIGHT        75.0
#define BADGE_MARGIN_X      60.0
#define BADGE_MARGIN_Y      80.0

//Drawing constants
#define BADGE_BG_COLOR          [NSColor lightGrayColor]
#define BADGE_VALID_COLOR       [NSColor colorWithCalibratedRed:(0/255.0) green:(98/255.0) blue:(25/255.0) alpha:1]
#define BADGE_EXPIRING_COLOR    [NSColor colorWithCalibratedRed:(146/255.0) green:(95/255.0) blue:(28/255.0) alpha:1]
#define BADGE_EXPIRED_COLOR     [NSColor colorWithCalibratedRed:(141/255.0) green:(0/255.0) blue:(7/255.0) alpha:1]
#define BADGE_FONT              [NSFont boldSystemFontOfSize:64]


OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);

/* -----------------------------------------------------------------------------
    Generate a thumbnail for file

   This function's job is to create thumbnail for designated file as fast as possible
   ----------------------------------------------------------------------------- */

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize) {
    @autoreleasepool {
        NSURL *URL = (__bridge NSURL *)url;
        NSString *dataType = (__bridge NSString *)contentTypeUTI;
        NSDictionary *optionsDict = (__bridge NSDictionary *)options;
        BOOL iconMode = ([optionsDict objectForKey:(NSString *)kQLThumbnailOptionIconModeKey]) ? YES : NO;
        NSData *provisionData = nil;
        NSData *appPlist = nil;
        NSImage *appIcon = nil;
        NSUInteger devicesCount = 0;
        int expStatus = 0;

        if ([dataType isEqualToString:kDataType_xcode_archive] || [dataType isEqualToString:kDataType_ipa_app_bundle]) {
            // get the embedded plist for the iOS app
            NSURL *appsDir = [URL URLByAppendingPathComponent:@"/"];
            if ([dataType isEqualToString:kDataType_xcode_archive]) {
                appsDir = [URL URLByAppendingPathComponent:@"Products/Applications/"];
            }
            if (appsDir != nil) {
                NSArray *dirFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir.path error:nil];
                if (dirFiles.count > 0) {
                    if ([dataType isEqualToString:kDataType_xcode_archive]) {
                        appPlist = [NSData dataWithContentsOfURL:[appsDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/Info.plist", dirFiles[0]]]];
                    } else if ([dataType isEqualToString:kDataType_ipa_app_bundle]) {
                        appPlist = [NSData dataWithContentsOfURL:[appsDir URLByAppendingPathComponent:@"Info.plist"]];
                    }
                }
            }
        } else if([dataType isEqualToString:kDataType_ipa]) {
            // get the embedded plist from an app archive using: unzip -p <URL> 'Payload/*.app/Info.plist' (piped to standard output)
            NSTask *unzipTask = [NSTask new];
            [unzipTask setLaunchPath:@"/usr/bin/unzip"];
            [unzipTask setStandardOutput:[NSPipe pipe]];
            [unzipTask setArguments:@[@"-p", [URL path], @"Payload/*.app/Info.plist", @"-x", @"*/*/*/*"]];
            [unzipTask launch];

            NSData *pipeData = [[[unzipTask standardOutput] fileHandleForReading] readDataToEndOfFile];
            [unzipTask waitUntilExit];

            appPlist = pipeData;
        } else {
            // use provisioning directly
            provisionData = [NSData dataWithContentsOfURL:URL];
        }

        if (QLThumbnailRequestIsCancelled(thumbnail)) {
            return noErr;
        }

        NSDictionary *propertiesDict = nil;
        if ([dataType isEqualToString:kDataType_ipa] || [dataType isEqualToString:kDataType_xcode_archive] || [dataType isEqualToString:kDataType_ipa_app_bundle]) {
            NSDictionary *appPropertyList = [NSPropertyListSerialization propertyListWithData:appPlist options:0 format:NULL error:NULL];
            NSString *iconName = mainIconNameForApp(appPropertyList);
            appIcon = imageFromApp(URL, dataType, iconName);

            if (!appIcon) {
                NSURL *iconURL = [[NSBundle bundleWithIdentifier:kPluginBundleId] URLForResource:@"defaultIcon" withExtension:@"png"];
                appIcon = [[NSImage alloc] initWithContentsOfURL:iconURL];
            }
            appIcon = roundCorners(appIcon);
            if ([dataType isEqualToString:kDataType_xcode_archive] || [dataType isEqualToString:kDataType_ipa_app_bundle]) {
                propertiesDict = @{@"IconFlavor" : @(12)};
            } else {
                propertiesDict = @{@"IconFlavor" : @(0)};
            }
        } else {
            if (iconMode) {
                NSURL *iconURL = [[NSBundle bundleWithIdentifier:kPluginBundleId] URLForResource:@"blankIcon" withExtension:@"png"];
                appIcon = [[NSImage alloc] initWithContentsOfURL:iconURL];
            } else {
                appIcon = [[NSWorkspace sharedWorkspace] iconForFileType:dataType];
                [appIcon setSize:NSMakeSize(512,512)];
            }

            if (!provisionData) {
                NSLog(@"No provisionData for %@", URL);
                return noErr;
            }

            CMSDecoderRef decoder = NULL;
            CMSDecoderCreate(&decoder);
            CMSDecoderUpdateMessage(decoder, provisionData.bytes, provisionData.length);
            CMSDecoderFinalizeMessage(decoder);
            CFDataRef dataRef = NULL;
            CMSDecoderCopyContent(decoder, &dataRef);
            NSData *data = (NSData *)CFBridgingRelease(dataRef);
            CFRelease(decoder);

            if (!data || QLThumbnailRequestIsCancelled(thumbnail)) {
                return noErr;
            }

            NSDictionary *propertyList = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            id value = [propertyList objectForKey:@"ProvisionedDevices"];
            if ([value isKindOfClass:[NSArray class]]) {
                devicesCount = [value count];
            }

            value = [propertyList objectForKey:@"ExpirationDate"];
            if ([value isKindOfClass:[NSDate class]]) {
                expStatus = expirationStatus(value, [NSCalendar currentCalendar]);
            }
        }

        if (QLThumbnailRequestIsCancelled(thumbnail)) {
            return noErr;
        }

        NSSize canvasSize = appIcon.size;
        NSRect renderRect = NSMakeRect(0.0, 0.0, appIcon.size.width, appIcon.size.height);

        CGContextRef _context = QLThumbnailRequestCreateContext(thumbnail, canvasSize, false, (__bridge CFDictionaryRef)propertiesDict);
        if (_context) {
            NSGraphicsContext *_graphicsContext = [NSGraphicsContext graphicsContextWithGraphicsPort:(void *)_context flipped:NO];

            [NSGraphicsContext setCurrentContext:_graphicsContext];
            if ([dataType isEqualToString:kDataType_ipa] || [dataType isEqualToString:kDataType_xcode_archive] || [dataType isEqualToString:kDataType_ipa_app_bundle]) {
                [appIcon drawInRect:renderRect];
            } else {
                [appIcon drawInRect:renderRect];

                NSString *badge = [NSString stringWithFormat:@"%lu",(unsigned long)devicesCount];
                NSColor *outlineColor;

                if (expStatus == 2) {
                    outlineColor = BADGE_VALID_COLOR;
                } else if (expStatus == 1) {
                    outlineColor = BADGE_EXPIRING_COLOR;
                } else {
                    outlineColor = BADGE_EXPIRED_COLOR;
                }

                NSMutableParagraphStyle *paragraphStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
                paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
                paragraphStyle.alignment = kCTTextAlignmentCenter;

                NSDictionary *attrDict = @{NSFontAttributeName : BADGE_FONT, NSForegroundColorAttributeName : outlineColor, NSParagraphStyleAttributeName: paragraphStyle};

                NSSize badgeNumSize = [badge sizeWithAttributes:attrDict];
                int badgeWidth = badgeNumSize.width + BADGE_MARGIN * 2;
                badgeWidth = MAX(badgeWidth, MIN_BADGE_WIDTH);

                int badgeX = renderRect.origin.x + BADGE_MARGIN_X;
                int badgeY = renderRect.origin.y + renderRect.size.height - BADGE_HEIGHT - BADGE_MARGIN_Y;
                if (!iconMode) {
                    badgeX += 75;
                    badgeY -= 10;
                }
                int badgeNumX = badgeX + BADGE_MARGIN;
                NSRect badgeRect = NSMakeRect(badgeX, badgeY, badgeWidth, BADGE_HEIGHT);

                NSBezierPath *badgePath = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:10 yRadius:10];
                [badgePath setLineWidth:8.0];
                [BADGE_BG_COLOR set];
                [badgePath fill];
                [outlineColor set];
                [badgePath stroke];

                [badge drawAtPoint:NSMakePoint(badgeNumX,badgeY) withAttributes:attrDict];
            }

            QLThumbnailRequestFlushContext(thumbnail, _context);
            CFRelease(_context);
        }
    }

    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview) {
    // Implement only if supported
}
