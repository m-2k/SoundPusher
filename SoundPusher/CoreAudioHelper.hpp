//
//  CoreAudioHelper.hpp
//  VirtualSound
//
//  Created by Daniel Vollmer on 14/12/2015.
//
//

#ifndef CoreAudioHelper_hpp
#define CoreAudioHelper_hpp

#include <vector>
#include <string>
#include <stdexcept>
#include "CoreAudio/CoreAudio.h"

namespace CAHelper {

std::string Get4CCAsString(const UInt32 val);

struct CoreAudioException : std::runtime_error { CoreAudioException(const OSStatus error); };

CFStringRef GetStringProperty(const AudioObjectID device, const AudioObjectPropertyAddress &address);

extern const AudioObjectPropertyAddress DeviceUIDAddress;
extern const AudioObjectPropertyAddress ObjectNameAddress;

std::vector<AudioStreamBasicDescription> GetStreamPhysicalFormats(const AudioObjectID stream);
std::vector<AudioObjectID> GetStreams(const AudioObjectID device, const bool input);
std::vector<AudioObjectID> GetDevices();

/// RAII class for changing the system default device
struct DefaultDeviceChanger
{
  DefaultDeviceChanger(const AudioObjectID claimedDevice, const AudioObjectID alternativeDevice);
  DefaultDeviceChanger(DefaultDeviceChanger &&) = delete; // non-copyable, non-movable
  ~DefaultDeviceChanger();
protected:
  AudioObjectID _originalDevice;
};

/// RAII class for hogging a device
struct DeviceHogger
{
  DeviceHogger(const AudioObjectID device, const bool shouldHog);
  DeviceHogger(DeviceHogger &&) = delete; // non-copyable, non-movable
  ~DeviceHogger();
protected:
  AudioObjectID _device;
  pid_t _hog_pid;
};

/// RAII class for setting a stream format (and restoring the original format on destruction)
struct FormatSetter
{
  FormatSetter(const AudioObjectID stream, const AudioStreamBasicDescription &format);
  FormatSetter(FormatSetter &&) = delete; // non-copyable, non-movable
  ~FormatSetter();
protected:
  AudioObjectID _stream;
  AudioStreamBasicDescription _originalFormat;
  bool _didChange;
};


} // end namespace CAHelper

#endif /* CoreAudioHelper_hpp */
