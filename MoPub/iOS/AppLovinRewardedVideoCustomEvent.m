//
//  AppLovinRewardedVideoCustomEvent.m
//
//
//  Created by Thomas So on 5/21/17.
//
//

#import "AppLovinRewardedVideoCustomEvent.h"
#import "MPRewardedVideoReward.h"
#import "MPError.h"

#if __has_include(<AppLovinSDK/AppLovinSDK.h>)
    #import <AppLovinSDK/AppLovinSDK.h>
#else
    #import "ALIncentivizedInterstitialAd.h"
#endif

// Convenience macro for checking if AppLovin SDK has support for zones
#define HAS_ZONES_SUPPORT [[ALSdk shared].adService respondsToSelector: @selector(loadNextAdForZoneIdentifier:andNotify:)]
#define DEFAULT_ZONE @""

// This class implementation with the old classname is left here for backwards compatibility purposes.
@implementation AppLovinRewardedCustomEvent
@end

@interface AppLovinRewardedVideoCustomEvent() <ALAdLoadDelegate, ALAdDisplayDelegate, ALAdVideoPlaybackDelegate, ALAdRewardDelegate>

@property (nonatomic, strong) ALIncentivizedInterstitialAd *incent;

@property (nonatomic, assign) BOOL fullyWatched;
@property (nonatomic, strong) MPRewardedVideoReward *reward;

@end

@implementation AppLovinRewardedVideoCustomEvent

static const BOOL kALLoggingEnabled = YES;
static NSString *const kALMoPubMediationErrorDomain = @"com.applovin.sdk.mediation.mopub.errorDomain";

// A dictionary of Zone -> `ALIncentivizedInterstitialAd` to be shared by instances of the custom event.
// This prevents skipping of ads as this adapter will be re-created and preloaded (along with underlying `ALIncentivizedInterstitialAd`)
// on every ad load regardless if ad was actually displayed or not.
static NSMutableDictionary<NSString *, ALIncentivizedInterstitialAd *> *ALGlobalIncentivizedInterstitialAds;

#pragma mark - Class Initialization

+ (void)initialize
{
    [super initialize];
    
    ALGlobalIncentivizedInterstitialAds = [NSMutableDictionary dictionary];
}

#pragma mark - MPRewardedVideoCustomEvent Overridden Methods

- (void)requestRewardedVideoWithCustomEventInfo:(NSDictionary *)info
{
    [self log: @"Requesting AppLovin rewarded video with info: %@", info];
    
    [[ALSdk shared] setPluginVersion: @"MoPub-2.1.0"];
    
    // Zones support is available on AppLovin SDK 4.5.0 and higher
    NSString *zoneIdentifier;
    if ( HAS_ZONES_SUPPORT && info[@"zone_id"] )
    {
        zoneIdentifier = info[@"zone_id"];
    }
    else
    {
        zoneIdentifier = DEFAULT_ZONE;
    }
    
    // Check if incentivized ad for zone already exists
    if ( ALGlobalIncentivizedInterstitialAds[zoneIdentifier] )
    {
        self.incent = ALGlobalIncentivizedInterstitialAds[zoneIdentifier];
    }
    else
    {
        // If this is a default Zone, create the incentivized ad normally
        if ( [DEFAULT_ZONE isEqualToString: zoneIdentifier] )
        {
            self.incent = [[ALIncentivizedInterstitialAd alloc] initWithSdk: [ALSdk shared]];
        }
        // Otherwise, use the Zones API
        else
        {
            self.incent = [self incentivizedInterstitialAdWithZoneIdentifier: zoneIdentifier];
        }
        
        ALGlobalIncentivizedInterstitialAds[zoneIdentifier] = self.incent;
    }
    
    self.incent.adVideoPlaybackDelegate = self;
    self.incent.adDisplayDelegate = self;
    
    [self.incent preloadAndNotify: self];
}

- (BOOL)hasAdAvailable
{
    return self.incent.readyForDisplay;
}

- (void)presentRewardedVideoFromViewController:(UIViewController *)viewController
{
    if ( [self hasAdAvailable] )
    {
        self.reward = nil;
        self.fullyWatched = NO;
        
        [self.incent showAndNotify: self];
    }
    else
    {
        [self log: @"Failed to show an AppLovin rewarded video before one was loaded"];
        
        NSError *error = [NSError errorWithDomain: kALMoPubMediationErrorDomain
                                             code: kALErrorCodeUnableToRenderAd
                                         userInfo: @{NSLocalizedFailureReasonErrorKey : @"Adaptor requested to display a rewarded video before one was loaded"}];
        
        [self.delegate rewardedVideoDidFailToPlayForCustomEvent: self error: error];
    }
}

- (void)handleCustomEventInvalidated { }
- (void)handleAdPlayedForCustomEventNetwork { }

#pragma mark - Ad Load Delegate

- (void)adService:(ALAdService *)adService didLoadAd:(ALAd *)ad
{
    [self log: @"Rewarded video did load ad: %@", ad.adIdNumber];
    [self.delegate rewardedVideoDidLoadAdForCustomEvent: self];
}

- (void)adService:(ALAdService *)adService didFailToLoadAdWithError:(int)code
{
    [self log: @"Rewarded video failed to load with error: %d", code];
    
    NSError *error = [NSError errorWithDomain: kALMoPubMediationErrorDomain
                                         code: [self toMoPubErrorCode: code]
                                     userInfo: nil];
    [self.delegate rewardedVideoDidFailToLoadAdForCustomEvent: self error: error];
    
    // TODO: Add support for backfilling on regular ad request if invalid zone entered
}

#pragma mark - Ad Display Delegate

- (void)ad:(ALAd *)ad wasDisplayedIn:(UIView *)view
{
    [self log: @"Rewarded video displayed"];
    
    [self.delegate rewardedVideoWillAppearForCustomEvent: self];
    [self.delegate rewardedVideoDidAppearForCustomEvent: self];
}

- (void)ad:(ALAd *)ad wasHiddenIn:(UIView *)view
{
    [self log: @"Rewarded video dismissed"];
    
    if ( self.fullyWatched && self.reward )
    {
        [self.delegate rewardedVideoShouldRewardUserForCustomEvent: self reward: self.reward];
    }
    
    [self.delegate rewardedVideoWillDisappearForCustomEvent: self];
    [self.delegate rewardedVideoDidDisappearForCustomEvent: self];
    
    self.incent = nil;
}

- (void)ad:(ALAd *)ad wasClickedIn:(UIView *)view
{
    [self log: @"Rewarded video clicked"];
    
    [self.delegate rewardedVideoDidReceiveTapEventForCustomEvent: self];
    [self.delegate rewardedVideoWillLeaveApplicationForCustomEvent: self];
}

#pragma mark - Video Playback Delegate

- (void)videoPlaybackBeganInAd:(ALAd *)ad
{
    [self log: @"Rewarded video video playback began"];
}

- (void)videoPlaybackEndedInAd:(ALAd *)ad atPlaybackPercent:(NSNumber *)percentPlayed fullyWatched:(BOOL)wasFullyWatched
{
    [self log: @"Rewarded video video playback ended at playback percent: %lu", percentPlayed.unsignedIntegerValue];
    
    self.fullyWatched = wasFullyWatched;
}

#pragma mark - Reward Delegate

- (void)rewardValidationRequestForAd:(ALAd *)ad didExceedQuotaWithResponse:(NSDictionary *)response
{
    [self log: @"Rewarded video validation request for ad did exceed quota with response: %@", response];
}

- (void)rewardValidationRequestForAd:(ALAd *)ad didFailWithError:(NSInteger)responseCode
{
    [self log: @"Rewarded video validation request for ad failed with error code: %ld", responseCode];
}

- (void)rewardValidationRequestForAd:(ALAd *)ad wasRejectedWithResponse:(NSDictionary *)response
{
    [self log: @"Rewarded video validation request was rejected with response: %@", response];
}

- (void)userDeclinedToViewAd:(ALAd *)ad
{
    [self log: @"User declined to view rewarded video"];
    
    [self.delegate rewardedVideoWillDisappearForCustomEvent: self];
    [self.delegate rewardedVideoDidDisappearForCustomEvent: self];
}

- (void)rewardValidationRequestForAd:(ALAd *)ad didSucceedWithResponse:(NSDictionary *)response
{
    NSNumber *amount = response[@"amount"];
    NSString *currency = response[@"currency"];
    
    [self log: @"Rewarded %@ %@", amount, currency];
    
    self.reward = [[MPRewardedVideoReward alloc] initWithCurrencyType: currency amount: amount];
}

#pragma mark - Incentivized Interstitial

/**
 * Dynamically create an instance of ALAdView with a given zone without breaking backwards compatibility for publishers on older SDKs.
 */
- (ALIncentivizedInterstitialAd *)incentivizedInterstitialAdWithZoneIdentifier:(NSString *)zoneIdentifier
{
    // Prematurely create instance of ALAdView to store initialized one in later
    ALIncentivizedInterstitialAd *incent = [ALIncentivizedInterstitialAd alloc];
    
    // We must use NSInvocation over performSelector: for initializers
    NSMethodSignature *methodSignature = [ALIncentivizedInterstitialAd instanceMethodSignatureForSelector: @selector(initWithZoneIdentifier:)];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature: methodSignature];
    [inv setSelector: @selector(initWithZoneIdentifier:)];
    [inv setArgument: &zoneIdentifier atIndex: 2];
    [inv setReturnValue: &incent];
    [inv invokeWithTarget: incent];
    
    return incent;
}

#pragma mark - Utility Methods

- (void)log:(NSString *)format, ...
{
    if ( kALLoggingEnabled )
    {
        va_list valist;
        va_start(valist, format);
        NSString *message = [[NSString alloc] initWithFormat: format arguments: valist];
        va_end(valist);
        
        NSLog(@"AppLovinRewardedVideoCustomEvent: %@", message);
    }
}

- (MOPUBErrorCode)toMoPubErrorCode:(int)appLovinErrorCode
{
    if ( appLovinErrorCode == kALErrorCodeNoFill )
    {
        return MOPUBErrorAdapterHasNoInventory;
    }
    else if ( appLovinErrorCode == kALErrorCodeAdRequestNetworkTimeout )
    {
        return MOPUBErrorNetworkTimedOut;
    }
    else if ( appLovinErrorCode == kALErrorCodeInvalidResponse )
    {
        return MOPUBErrorServerError;
    }
    else
    {
        return MOPUBErrorUnknown;
    }
}

@end
