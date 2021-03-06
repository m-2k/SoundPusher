//
//  AppDelegate.mm
//  SoundPusher
//
//  Created by Daniel Vollmer on 14/12/2015.
//
//

#include <memory>
#include <algorithm>
extern "C" {
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
} // end extern "C"

extern "C" {
#include "LoopbackAudio.h"
} // end extern "C"
#include "MiniLogger.hpp"
#include "CoreAudioHelper.hpp"
#include "DigitalOutputContext.hpp"
#include "ForwardingInputTap.hpp"

#import "ForwardingChainIdentifier.h"
#import "AppDelegate.h"

@interface AppDelegate ()
@property (weak) IBOutlet NSMenu *statusItemMenu;
@property (weak) IBOutlet NSMenuItem *upmixMenuItem;
@end

@implementation AppDelegate

/// Stream with compatible formats.
struct Stream
{
  Stream(const AudioObjectID stream, std::vector<AudioStreamBasicDescription> &&formats)
  : _stream(stream)
  , _formats(std::move(formats))
  { }

  AudioObjectID _stream;
  std::vector<AudioStreamBasicDescription> _formats;
};

/// Device with compatible streams (that contain compatible formats).
struct Device
{
  Device(const AudioObjectID device, std::vector<Stream> &&streams)
  : _device(device)
  , _uid(CFBridgingRelease(CAHelper::GetStringProperty(_device, CAHelper::DeviceUIDAddress)))
  , _streams(std::move(streams))
  { }

  bool Contains(ForwardingChainIdentifier *identifier) const
  {
    if (![_uid isEqualToString:identifier.outDeviceUID])
      return false;
    if (identifier.outStreamIndex >= _streams.size())
    {
      DefaultLogger.Warning("Device %s has %zu streams, but checked one is %zu", _uid.UTF8String, _streams.size(), identifier.outStreamIndex);
      return false;
    }
    return true;
  }

  AudioObjectID _device;
  NSString *_uid;
  std::vector<Stream> _streams;
};

static std::vector<Device> GetDevicesWithDigitalOutput(const std::vector<AudioObjectID> &allDevices)
{
  std::vector<Device> result;
  for (const auto device : allDevices)
  {
    const auto streams = CAHelper::GetStreams(device, false /* outputs */);
    std::vector<Stream> digitalStreams;
    for (const auto stream : streams)
    {
      const auto formats = CAHelper::GetStreamPhysicalFormats(stream);
      auto digitalFormats = decltype(formats){};
      std::copy_if(formats.begin(), formats.end(), std::back_inserter(digitalFormats), [](const AudioStreamBasicDescription &format)
      {
        if (format.mSampleRate != 48000.0)
          return false;
        return format.mFormatID == kAudioFormatAC3 ||
               format.mFormatID == kAudioFormat60958AC3 ||
               format.mFormatID == 'IAC3' ||
               format.mFormatID == 'iac3';

      });
      if (!digitalFormats.empty())
        digitalStreams.emplace_back(Stream{stream, std::move(digitalFormats)});
    }
    if (!digitalStreams.empty())
      result.emplace_back(Device{device, std::move(digitalStreams)});
  }
  return result;
}

static std::vector<Device> GetLoopbackDevicesWithInput(const std::vector<AudioObjectID> &allDevices)
{
  std::vector<Device> result;
  for (const auto device : allDevices)
  {
    NSString *uidString = CFBridgingRelease(CAHelper::GetStringProperty(device, CAHelper::DeviceUIDAddress));
    if (![uidString isEqualToString:[NSString stringWithUTF8String:kLoopbackAudioDevice_UID]])
      continue;

    const auto streams = CAHelper::GetStreams(device, true /* inputs */);
    std::vector<Stream> matchingStreams;
    for (const auto stream : streams)
    {
      auto formats = CAHelper::GetStreamPhysicalFormats(stream);
      if (!formats.empty())
        matchingStreams.emplace_back(Stream{stream, std::move(formats)});
    }
    if (!matchingStreams.empty())
      result.emplace_back(Device{device, std::move(matchingStreams)});
  }
  return result;
}

static const AudioObjectPropertyAddress DeviceAliveAddress = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};

// forward declaration (because this func needs access to _chains, but _chains needs to know the type of ForwardingChain)
static OSStatus DeviceAliveListenerFunc(AudioObjectID inObjectID, UInt32 inNumberAddresses,
  const AudioObjectPropertyAddress *inAddresses, void *inClientData);

struct ForwardingChain
{
  ForwardingChain(ForwardingChainIdentifier *identifier, AudioObjectID inDevice, AudioObjectID inStream,
    AudioObjectID outDevice, AudioObjectID outStream, const AudioStreamBasicDescription &outFormat,
    const AudioChannelLayoutTag channelLayoutTag)
  : _identifier(identifier)
  , _defaultDevice(outDevice, inDevice)
  , _output(outDevice, outStream, outFormat, channelLayoutTag)
  , _input(inDevice, inStream, _output)
  {
    OSStatus status = AudioObjectAddPropertyListener(_output._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
    if (status != noErr)
      DefaultLogger.Warning("Could not register alive-listener for output device %u", _output._device);
    status = AudioObjectAddPropertyListener(_input._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
    if (status != noErr)
      DefaultLogger.Warning("Could not register alive-listener for input device %u", _input._device);
  }

  ~ForwardingChain()
  {
    OSStatus status = AudioObjectRemovePropertyListener(_output._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
    if (status != noErr)
      DefaultLogger.Warning("Could not remove alive-listener for output device %u", _output._device);
    status = AudioObjectRemovePropertyListener(_input._device, &DeviceAliveAddress, DeviceAliveListenerFunc, this);
    if (status != noErr)
      DefaultLogger.Warning("Could not remove alive-listener for input device %u", _input._device);
  }

  ForwardingChainIdentifier *_identifier;
  CAHelper::DefaultDeviceChanger _defaultDevice;
  DigitalOutputContext _output;
  ForwardingInputTap _input;
};

// our status menu item
NSStatusItem *_statusItem = nil;
// the list of chains which we want to be active (but which may not be, e.g. due to disconnected devices etc).
NSMutableSet<ForwardingChainIdentifier *> *_desiredActiveChains = [NSMutableSet new];
// the actual instances of running chains
std::vector<std::unique_ptr<ForwardingChain>> _chains;
// how many menu items were in the menu originally (because we keep rebuilding parts of it)
NSInteger _numOriginalMenuItems = 0;
bool _enableUpmix = false;


static void UpdateStatusItem()
{
  if (_chains.empty())
  {
    _statusItem.button.image = [NSImage imageNamed:@"CableCutTemplate"];
    _statusItem.button.appearsDisabled = YES;
  }
  else
  {
    _statusItem.button.image = [NSImage imageNamed:@"CableTemplate"];
    _statusItem.button.appearsDisabled = NO;
  }
}

static OSStatus DeviceAliveListenerFunc(AudioObjectID inObjectID, UInt32 inNumberAddresses,
  const AudioObjectPropertyAddress *inAddresses, void *inClientData)
{
  const bool chainsWereEmpty  = _chains.empty();
  ForwardingChain *oldChain = static_cast<ForwardingChain *>(inClientData);
  for (auto it = _chains.begin(); it != _chains.end(); /* in body */)
  {
    const auto &chain = *it;
    if (chain.get() == oldChain)
    {
      assert(chain->_output._device == inObjectID || chain->_input._device == inObjectID);
      it = _chains.erase(it);
    }
    else
      ++it;
  }

  if (chainsWereEmpty != _chains.empty())
  {
    dispatch_async(dispatch_get_main_queue(), ^{
      UpdateStatusItem();
    });
  }

  return noErr;
}


static void AttemptToStartMissingChains()
{
  const auto allDevices = CAHelper::GetDevices();
  const auto loopbackDevices = GetLoopbackDevicesWithInput(allDevices);
  if (loopbackDevices.empty())
    return;

  // which devices are currently available
  const auto outputDevices = GetDevicesWithDigitalOutput(allDevices);
  NSMutableSet<ForwardingChainIdentifier *> *desired = [NSMutableSet setWithCapacity:outputDevices.size()];
  for (const auto &outDevice : outputDevices)
  {
      for (auto i = NSUInteger{0}; i < outDevice._streams.size(); ++i)
        [desired addObject:[[ForwardingChainIdentifier alloc] initWithOutDeviceUID:outDevice._uid andOutStreamIndex:i]];
  }

  // which devices are currently running
  NSMutableSet<ForwardingChainIdentifier *> *running = [NSMutableSet setWithCapacity:_chains.size()];
  for (const auto &chain : _chains)
    [running addObject:chain->_identifier];

  [desired intersectSet:_desiredActiveChains];
  [desired minusSet:running];

  for (ForwardingChainIdentifier *attempt in desired)
  {
    // find the device in the actual device list
    const auto outDeviceIt = std::find_if(outputDevices.cbegin(), outputDevices.cend(), [attempt](const Device &device)
    {
      return device.Contains(attempt);
    });
    assert(outDeviceIt != outputDevices.cend());

    const auto &inDevice = loopbackDevices.front();
    const auto &outDevice = *outDeviceIt;
    const auto &outStream = outDevice._streams[attempt.outStreamIndex];
    try
    { // create and start-up first
      auto newChain = std::make_unique<ForwardingChain>(attempt, inDevice._device, inDevice._streams.front()._stream,
        outDevice._device, outStream._stream, outStream._formats.front(), kAudioChannelLayoutTag_AudioUnit_5_1);

      newChain->_output.SetUpmix(_enableUpmix);

      newChain->_input.Start();
      newChain->_output.Start();

      // and only add if everything worked so far
      _chains.emplace_back(std::move(newChain));
    }
    catch (const std::exception &e)
    {
      DefaultLogger.Err("Could not initialize chain %s: %s", attempt.description.UTF8String, e.what());
    }
  }
  UpdateStatusItem();
}


- (void)toggleOutputDeviceAction:(NSMenuItem *)item
{
  const bool chainsWereEmpty = _chains.empty();
  ForwardingChainIdentifier *identifier = item.representedObject;
  if (item.state == NSOnState)
  { // should try to stop chain
    bool didFind = false;
    for (auto it = _chains.begin(); it != _chains.end(); /* in body */)
    {
      const auto &chain = *it;
      if ([chain->_identifier isEqual:identifier])
      {
        didFind = true;
        it =_chains.erase(it);
      }
      else
        ++it;
    }
    // also remove from desired active
    [_desiredActiveChains removeObject:identifier];
    [[NSUserDefaults standardUserDefaults] setObject:[_desiredActiveChains.allObjects valueForKey:@"asDictionary"] forKey:@"ActiveChains"];
    if (!didFind)
      DefaultLogger.Warning("Could not disable chain %s: Not found / active", identifier.description.UTF8String);
  }
  else
  { // try to add the chain
    const auto allDevices = CAHelper::GetDevices();
    const auto loopbackDevices = GetLoopbackDevicesWithInput(allDevices);
    if (loopbackDevices.empty())
    {
      DefaultLogger.Err("LoopbackAudio device is gone, cannot start chain");
      return;
    }
    const auto outputDevices = GetDevicesWithDigitalOutput(allDevices);
    for (const auto &outDevice : outputDevices)
    {
      if (!outDevice.Contains(identifier))
        continue;

      const auto &inDevice = loopbackDevices.front();
      const auto &outStream = outDevice._streams[identifier.outStreamIndex];
      try
      { // create and start-up first
        auto newChain = std::make_unique<ForwardingChain>(identifier, inDevice._device, inDevice._streams.front()._stream,
          outDevice._device, outStream._stream, outStream._formats.front(), kAudioChannelLayoutTag_AudioUnit_5_1);

        newChain->_output.SetUpmix(_enableUpmix);

        newChain->_input.Start();
        newChain->_output.Start();

        // and only add if everything worked so far
        _chains.emplace_back(std::move(newChain));
        [_desiredActiveChains addObject:identifier];
        [[NSUserDefaults standardUserDefaults] setObject:[_desiredActiveChains.allObjects valueForKey:@"asDictionary"] forKey:@"ActiveChains"];
      }
      catch (const std::exception &e)
      {
        DefaultLogger.Err("Could not initialize chain %s: %s", identifier.description.UTF8String, e.what());
      }
      break;
    }
  }
  if (_chains.empty() != chainsWereEmpty)
    UpdateStatusItem();
}

- (IBAction)toggleUpmix:(NSMenuItem *)item
{
  const auto newState = (item.state == NSOnState) ? NSOffState : NSOnState;
  item.state = newState;
  if (_enableUpmix != (newState == NSOnState))
  {
    _enableUpmix = (newState == NSOnState);
    [[NSUserDefaults standardUserDefaults] setBool:_enableUpmix forKey:@"Upmix" ];

    for (const auto &chain : _chains)
      chain->_output.SetUpmix(_enableUpmix);
  }
}


- (void)menuNeedsUpdate:(NSMenu *)menu
{
  bool showDebugInfo = ([NSEvent modifierFlags] & NSAlternateKeyMask) != 0;
  // remove old chain menu items
  while (menu.numberOfItems > _numOriginalMenuItems)
    [menu removeItemAtIndex:0];

  const auto allDevices = CAHelper::GetDevices();

  NSUInteger insertionIndex = 0;
  const auto loopbackDevices = GetLoopbackDevicesWithInput(allDevices);
  if (loopbackDevices.empty())
  {
    NSMenuItem *item = [NSMenuItem new];
    item.title = @"No LoopbackAudio device";
    item.enabled = NO;
    [menu insertItem:item atIndex:insertionIndex];
    ++insertionIndex;
  }

  const auto outputDevices = GetDevicesWithDigitalOutput(allDevices);
  if (outputDevices.empty())
  {
    NSMenuItem *item = [NSMenuItem new];
    item.title = @"No (digital) output device";
    item.enabled = NO;
    [menu insertItem:item atIndex:insertionIndex];
    ++insertionIndex;
  }
  for (const auto &device : outputDevices)
  {
    NSString *deviceName = CFBridgingRelease(CAHelper::GetStringProperty(device._device, CAHelper::ObjectNameAddress));

    for (auto i = NSUInteger{0}; i < device._streams.size(); ++i)
    {
      ForwardingChainIdentifier *identifier = [[ForwardingChainIdentifier alloc] initWithOutDeviceUID:device._uid andOutStreamIndex:i];
      const AudioStreamBasicDescription &format = device._streams[i]._formats.front();
      NSMenuItem *item = [NSMenuItem new];
      item.title = deviceName;
      item.enabled = !loopbackDevices.empty();
      const auto chainIt = std::find_if(_chains.cbegin(), _chains.cend(), [identifier](const std::unique_ptr<ForwardingChain> &chain)
      {
        return [identifier isEqual:chain->_identifier];
      });
      const bool isActive = chainIt != _chains.cend();
      item.state = isActive ? NSOnState : NSOffState;
      item.representedObject = identifier;
      item.action = @selector(toggleOutputDeviceAction:);
      item.target = self;
      [menu insertItem:item atIndex:insertionIndex];
      ++insertionIndex;
      if (showDebugInfo)
      {
        NSMenuItem *item = [NSMenuItem new];
        item.title = [NSString stringWithFormat:@"%.0fHz %u bytes/packet %u frames/packet [%s]", format.mSampleRate, format.mBytesPerPacket, format.mFramesPerPacket, CAHelper::Get4CCAsString(format.mFormatID).c_str()];
        item.enabled = NO;
        [menu insertItem:item atIndex:insertionIndex];
        ++insertionIndex;
      }
    }
  }
}

- (IBAction)openHomepage:(id)sender
{
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/q-p/SoundPusher"]];
}

- (void) receiveSleepNote: (NSNotification*) note
{
  _chains.clear();
}
 
- (void) receiveWakeNote: (NSNotification*) note
{
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    AttemptToStartMissingChains();
  });
}
 
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
  // register defaults
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"LogLevel" : [NSNumber numberWithInt:MiniLogger::LogWarning],
    @"Upmix" : [NSNumber numberWithBool:NO],
    @"ActiveChains" : @[]
  }];

  { // read defaults
    const NSInteger level = std::max(static_cast<NSInteger>(MiniLogger::LogEmergency),
      std::min(static_cast<NSInteger>(MiniLogger::LogDebug),
        [[NSUserDefaults standardUserDefaults] integerForKey:@"LogLevel"]));
    DefaultLogger.SetLevel(static_cast<MiniLogger::Level>(level));

    _enableUpmix = [[NSUserDefaults standardUserDefaults] boolForKey:@"Upmix"];

    NSArray<NSDictionary *> *desiredActiveArray = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ActiveChains"];
    for (NSDictionary *dict in desiredActiveArray)
    {
      if (![dict isKindOfClass:NSDictionary.class])
        continue;
      ForwardingChainIdentifier *identifier = [ForwardingChainIdentifier identifierWithDictionary:dict];
      if (!identifier)
        continue;
      [_desiredActiveChains addObject:identifier];
    }
  }

  _numOriginalMenuItems = self.statusItemMenu.numberOfItems; // so we know how many to keep when updating the menu

  _upmixMenuItem.state = _enableUpmix ? NSOnState : NSOffState;

#ifdef DEBUG
  av_log_set_level(AV_LOG_VERBOSE);
#else
  av_log_set_level(AV_LOG_ERROR);
#endif
  avcodec_register_all();
  av_register_all();

  {
    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    _statusItem = [bar statusItemWithLength:NSSquareStatusItemLength];
    _statusItem.button.image = [NSImage imageNamed:@"CableCutTemplate"];
    _statusItem.button.appearsDisabled = YES;
    [_statusItem setMenu:self.statusItemMenu];
  }

  AttemptToStartMissingChains();

  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(receiveSleepNote:)
    name:NSWorkspaceWillSleepNotification object:NULL];
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(receiveWakeNote:)
    name:NSWorkspaceDidWakeNotification object:NULL];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];

  _chains.clear();

  [_statusItem.statusBar removeStatusItem:_statusItem];
}

@end
