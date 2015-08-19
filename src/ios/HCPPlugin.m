//
//  HCPPlugin.m
//  TestIosCHCP
//
//  Created by Nikolay Demyankov on 07.08.15.
//
//

#import "HCPPlugin.h"
#import "HCPApplicationConfig+Downloader.h"
#import "HCPContentManifest+Downloader.h"
#import "HCPFileDownloader.h"
#import "HCPFilesStructure.h"
#import "HCPFilesStructureImpl.h"
#import "HCPUpdateLoader.h"
#import "HCPEvents.h"
#import "HCPPluginConfig+UserDefaults.h"
#import "HCPUpdateInstaller.h"
#import "NSJSONSerialization+HCPExtension.h"
#import "CDVPluginResult+HCPEvent.h"
#import "HCPXmlConfig.h"
#import "NSBundle+HCPExtension.h"
#import <Cordova/CDVConfigParser.h>

// Socket IO support:
// 1) Add hook to copy files from: https://github.com/socketio/socket.io-client-swift/tree/master/SocketIOClientSwift
// 2) Add hook to enable support for swift: https://github.com/cowbell/cordova-plugin-geofence/blob/20de72b918c779511919f7e38d07721112d4f5c8/hooks/add_swift_support.js
// Additional info: http://stackoverflow.com/questions/25448976/how-to-write-cordova-plugin-in-swift
// Cordova swift example: https://github.com/edewit/cordova-plugin-hello/tree/swift
// http://chrisdell.info/blog/writing-ios-cordova-plugin-pure-swift/


@interface HCPPlugin() {
    id<HCPFilesStructure> _filesStructure;
    HCPUpdateLoader *_updatesLoader;
    NSString *_defaultCallbackID;
    NSString *_wwwFolderPathInBundle;
    BOOL _isPluginReadyForWork;
    HCPPluginConfig *_pluginConfig;
    HCPUpdateInstaller *_updateInstaller;
    NSMutableArray *_fetchTasks;
    NSString *_installationCallback;
    HCPXmlConfig *_pluginXmllConfig;
}

@end

static NSString *const BLANK_PAGE = @"about:blank";
static NSString *const WWW_FOLDER_IN_BUNDLE = @"www";

@implementation HCPPlugin

// TODO: test when update is running and we press Home button

#pragma mark Lifecycle

- (CDVPlugin *)initWithWebView:(UIWebView *)theWebView {
    [theWebView setHidden:YES];
    
    return [super initWithWebView:theWebView];
}

-(void)pluginInitialize {    
    [self subscribeToEvents];
    [self initVariables];
    [self installWwwFolderIfNeeded];
    [self redirectToLocalStorage];
    
    // launch update download
    if (_pluginConfig.isUpdatesAutoDowloadAllowed) {
        [self jsFetchUpdate:nil];
    }
}

- (void)onAppTerminate {
    [self unsubscribeFromEvents];
}

- (void)onResume:(NSNotification *)notification {
    NSLog(@"onResume is called");
}

- (void)onPause:(NSNotification *)notification {
    NSLog(@"onPause is called");
}

#pragma mark Private API

- (void)installWwwFolderIfNeeded {
    NSError *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isApplicationUpdated = [NSBundle applicationBuildVersion] > _pluginConfig.appBuildVersion;
    BOOL isWWwFolderExists = [fileManager fileExistsAtPath:_filesStructure.wwwFolder.path];
    if (!isApplicationUpdated && isWWwFolderExists) {
        _isPluginReadyForWork = YES;
        return;
    }
    
    // remove previous version of the www folder
    if (isWWwFolderExists) {
        [fileManager removeItemAtURL:[_filesStructure.wwwFolder URLByDeletingLastPathComponent] error:&error];
    }
    
    // create new www folder
    if (![fileManager createDirectoryAtURL:[_filesStructure.wwwFolder URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"%@", [error.userInfo[NSUnderlyingErrorKey] localizedDescription]);
        return;
    }
    
    // copy www folder from bundle to cache folder
    NSURL *localWww = [NSURL fileURLWithPath:[self pathToWwwFolderInBundle] isDirectory:YES];
    _isPluginReadyForWork = [fileManager copyItemAtURL:localWww toURL:_filesStructure.wwwFolder error:&error];
    if (error) {
        NSLog(@"%@", [error.userInfo[NSUnderlyingErrorKey] localizedDescription]);
        return;
    }
    
    // update stored config with new application build version
    _pluginConfig.appBuildVersion = [NSBundle applicationBuildVersion];
    [_pluginConfig saveToUserDefaults];
}

- (void)initVariables {
    _isPluginReadyForWork = NO;
    _fetchTasks = [[NSMutableArray alloc] init];
    _filesStructure = [[HCPFilesStructureImpl alloc] init];
    
    _pluginXmllConfig = [HCPXmlConfig loadFromCordovaConfigXml];
    _pluginConfig = [HCPPluginConfig loadFromUserDefaults];
    if (_pluginConfig == nil) {
        _pluginConfig = [HCPPluginConfig defaultConfig];
        [_pluginConfig saveToUserDefaults];
    }
    
    _pluginConfig.configUrl = _pluginXmllConfig.configUrl;
    
    _updatesLoader = [HCPUpdateLoader sharedInstance];
    [_updatesLoader setup:_filesStructure];
    
    _updateInstaller = [HCPUpdateInstaller sharedInstance];
    [_updateInstaller setup:_filesStructure];
}

- (void)_fetchUpdate:(NSString *)callbackId {
    if (!_isPluginReadyForWork) {
        return;
    }
    
    NSString *taskId = [_updatesLoader addUpdateTaskToQueueWithConfigUrl:_pluginConfig.configUrl];
    [self storeCallback:callbackId forFetchTask:taskId];
}

- (void)storeCallback:(NSString *)callbackId forFetchTask:(NSString *)taskId {
    if (callbackId == nil || taskId == nil) {
        return;
    }
    
    NSDictionary *dict = @{taskId:callbackId};
    if (_fetchTasks.count < 2) {
        [_fetchTasks addObject:dict];
    } else {
        [_fetchTasks replaceObjectAtIndex:1 withObject:dict];
    }
}

- (NSString *)pollCallbackForTask:(NSString *)taskId {
    NSString *callbackId = nil;
    NSInteger index = -1;
    
    for (NSInteger i=0, len=_fetchTasks.count; i<len; i++) {
        NSDictionary *dict = _fetchTasks[i];
        NSString *storedCallbackId = dict[taskId];
        if (storedCallbackId) {
            callbackId = storedCallbackId;
            index = i;
            break;
        }
    }
    
    if (callbackId) {
        [_fetchTasks removeObjectAtIndex:index];
    }
    
    return callbackId;
}

- (void)_installUpdate:(NSString *)callbackID {
    if (!_isPluginReadyForWork) {
        return;
    }

    NSError *error = nil;
    if (![_updateInstaller launchUpdateInstallation:&error]) {
        //TODO: send nothing to update message
        return;
    }

    if (callbackID) {
        _installationCallback = callbackID;
    }
    
    //TODO: show progress dialog
}

- (void)loadURL:(NSURL *)url {
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)redirectToLocalStorage {
    NSString *currentUrl = self.webView.request.URL.path;
    if (currentUrl.length == 0 || [currentUrl isEqualToString:BLANK_PAGE] || [currentUrl containsString:_filesStructure.wwwFolder.path]) {
        return;
    }
    
    currentUrl = [currentUrl stringByReplacingOccurrencesOfString:[self pathToWwwFolderInBundle] withString:@""];
    NSURL *externalUrl = [_filesStructure.wwwFolder URLByAppendingPathComponent:currentUrl];
    if (![[NSFileManager defaultManager] fileExistsAtPath:externalUrl.path]) {
        return;
    }
    
    [self loadURL:externalUrl];
}

- (NSURL *)getStartingPageURL {
    NSString *startPage = nil;
    if ([self.viewController isKindOfClass:[CDVViewController class]]) {
        startPage = ((CDVViewController *)self.viewController).startPage;
    } else {
        startPage = [self getStartingPageFromConfig];
    }
    
    return [_filesStructure.wwwFolder URLByAppendingPathComponent:startPage];
}

- (NSString *)getStartingPageFromConfig {
    CDVConfigParser* delegate = [[CDVConfigParser alloc] init];
    
    // read from config.xml in the app bundle
    NSString* path = [[NSBundle mainBundle] pathForResource:@"config" ofType:@"xml"];
    NSURL* url = [NSURL fileURLWithPath:path];
    
    NSXMLParser *configParser = [[NSXMLParser alloc] initWithContentsOfURL:url];
    [configParser setDelegate:((id <NSXMLParserDelegate>)delegate)];
    [configParser parse];
    
    if (delegate.startPage) {
        return delegate.startPage;
    }
    
    return @"index.html";
}

- (NSString *)pathToWwwFolderInBundle {
    if (_wwwFolderPathInBundle == nil) {
        _wwwFolderPathInBundle = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:WWW_FOLDER_IN_BUNDLE];
    }
    
    return _wwwFolderPathInBundle;
}

- (void)invokeDefaultCallbackWithMessage:(CDVPluginResult *)result {
    if (_defaultCallbackID == nil) {
        return;
    }
    [result setKeepCallbackAsBool:YES];
    
    [self.commandDelegate sendPluginResult:result callbackId:_defaultCallbackID];
}

#pragma mark Events

- (void)subscribeToEvents {
    [self subscriveToLifecycleEvents];
    [self subscribeToCordovaEvents];
    [self subscriveToPluginInternalEvents];
}

- (void)subscribeToCordovaEvents {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self selector:@selector(didLoadWebPage:) name:CDVPageDidLoadNotification object:nil];
}

- (void)subscriveToLifecycleEvents {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self selector:@selector(onPause:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [notificationCenter addObserver:self selector:@selector(onResume:) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)subscriveToPluginInternalEvents {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    // update download events
    [notificationCenter addObserver:self selector:@selector(onUpdateDownloadErrorEvent:) name:kHCPUpdateDownloadErrorEvent object:nil];
    [notificationCenter addObserver:self selector:@selector(onNothingToUpdateEvent:) name:kHCPNothingToUpdateEvent object:nil];
    [notificationCenter addObserver:self selector:@selector(onUpdateIsReadyForInstallation:) name:kHCPUpdateIsReadyForInstallationEvent object:nil];
    
    // update installation events
    [notificationCenter addObserver:self selector:@selector(onUpdateInstallationErrorEvent:) name:kHCPUpdateInstallationErrorEvent object:nil];
    [notificationCenter addObserver:self selector:@selector(onUpdateInstalledEvent:) name:kHCPUpdateIsInstalledEvent object:nil];
    
}

- (void)unsubscribeFromEvents {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Cordova events

- (void)didLoadWebPage:(NSNotification *)notification {
    [self.webView setHidden:NO];
}

#pragma mark Update download events

- (void)onUpdateDownloadErrorEvent:(NSNotification *)notification {
    NSError *error = notification.userInfo[kHCPEventUserInfoErrorKey];
    NSLog(@"Error during update: %@", error.userInfo[NSLocalizedDescriptionKey]);
    
    CDVPluginResult *pluginResult = [CDVPluginResult pluginResultForNotification:notification];
    NSString *callbackID = [self pollCallbackForTask:notification.userInfo[kHCPEventUserInfoTaskIdKey]];
    if (callbackID) {
        [self.commandDelegate sendPluginResult:pluginResult callbackId:callbackID];
    }
    
    [self invokeDefaultCallbackWithMessage:pluginResult];
}

- (void)onNothingToUpdateEvent:(NSNotification *)notification {
    NSLog(@"Nothing to update");
    
    CDVPluginResult *pluginResult = [CDVPluginResult pluginResultForNotification:notification];
    NSString *callbackID = [self pollCallbackForTask:notification.userInfo[kHCPEventUserInfoTaskIdKey]];
    if (callbackID) {
        [self.commandDelegate sendPluginResult:pluginResult callbackId:callbackID];
    }
    
    [self invokeDefaultCallbackWithMessage:pluginResult];
}

- (void)onUpdateIsReadyForInstallation:(NSNotification *)notification {
    NSLog(@"Update is ready for installation");
    
    CDVPluginResult *pluginResult = [CDVPluginResult pluginResultForNotification:notification];
    NSString *callbackID = [self pollCallbackForTask:notification.userInfo[kHCPEventUserInfoTaskIdKey]];
    if (callbackID) {
        [self.commandDelegate sendPluginResult:pluginResult callbackId:callbackID];
    }
    [self invokeDefaultCallbackWithMessage:pluginResult];
    
    HCPApplicationConfig *newConfig = notification.userInfo[kHCPEventUserInfoApplicationConfigKey];
    if (_pluginConfig.isUpdatesAutoInstallationAllowed && newConfig.contentConfig.updateTime == HCPUpdateNow) {
        [self _installUpdate:nil];
    }
}

#pragma mark Update installation events

- (void)onUpdateInstallationErrorEvent:(NSNotification *)notification {
    CDVPluginResult *pluginResult = [CDVPluginResult pluginResultForNotification:notification];
    
    if (_installationCallback) {
        [self.commandDelegate sendPluginResult:pluginResult callbackId:_installationCallback];
        _installationCallback = nil;
    }
    
    [self invokeDefaultCallbackWithMessage:pluginResult];
    
    // TODO: hide installation progress dialog
    
}

- (void)onUpdateInstalledEvent:(NSNotification *)notification {
    CDVPluginResult *pluginResult = [CDVPluginResult pluginResultForNotification:notification];
    
    if (_installationCallback) {
        [self.commandDelegate sendPluginResult:pluginResult callbackId:_installationCallback];
        _installationCallback = nil;
    }
    
    [self invokeDefaultCallbackWithMessage:pluginResult];
    
    // TODO: remove installation progress dialog
    
    [self loadURL:[self getStartingPageURL]];
}

#pragma mark Methods, invoked from Javascript

- (void)jsInitPlugin:(CDVInvokedUrlCommand *)command {
    _defaultCallbackID = command.callbackId;
}

- (void)jsConfigure:(CDVInvokedUrlCommand *)command {
    if (!_isPluginReadyForWork) {
        return;
    }
    
    NSError *error = nil;
    id options = [NSJSONSerialization JSONObjectWithContentsFromString:command.arguments[0] error:&error];
    if (error) {
        [self.commandDelegate sendPluginResult:nil callbackId:command.callbackId];
        return;
    }
    
    [_pluginConfig mergeOptionsFromJS:options];
    [_pluginConfig saveToUserDefaults];
    
    [self.commandDelegate sendPluginResult:nil callbackId:command.callbackId];
}

- (void)jsFetchUpdate:(CDVInvokedUrlCommand *)command {
    if (!_isPluginReadyForWork) {
        return;
    }
    
    [self _fetchUpdate:command.callbackId];
}

- (void)jsInstallUpdate:(CDVInvokedUrlCommand *)command {
    if (!_isPluginReadyForWork) {
        return;
    }
    
    [self _installUpdate:command.callbackId];
}


@end
