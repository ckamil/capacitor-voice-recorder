# Custom Changes Log

## v7.1.0-interruption.1 (2024-08-19)

### 🎯 Added
- **iOS interruption handling** via AVAudioSessionInterruptionNotification
- **Android audio focus management** with AudioFocusRequest and OnAudioFocusChangeListener
- **TypeScript events**: `recordingInterrupted` and `interruptionEnded`
- **Automatic pause/resume** on system interruptions (phone calls, other apps)
- **User notification system** for interruption states
- **Recording status monitoring** to detect unexpected stops
- **Graceful degradation** for older Android versions

### 📱 Platform Support
- **iOS**: Full interruption handling with AVAudioSession
- **Android**: Audio focus handling (SDK 24+ for pause/resume)
- **Web**: Event structure defined (native handling not applicable)

### 🔧 Technical Implementation
- Added interruption data interfaces with reason tracking
- Integrated with Capacitor's plugin listener system
- Automatic cleanup of audio session resources
- Background-compatible audio session management

### 🎛️ New Events
```typescript
// Listen for recording interruptions
VoiceRecorder.addListener('recordingInterrupted', (event) => {
  console.log('Interrupted:', event.data.reason); // 'system_interruption', 'audio_focus_loss', etc.
});

// Listen for interruption end
VoiceRecorder.addListener('interruptionEnded', (event) => {
  console.log('Can resume:', event.canResume);
});
```

### 🐛 Fixed
- Recording continues when device goes to sleep (iOS)
- Recording lost when phone call interrupts (iOS/Android)
- No notification when other apps take audio focus (Android)
- App unaware of recording state changes

### 🔄 Upstream Sync
- Based on upstream v7.0.5 (tchvu3/capacitor-voice-recorder)
- Maintains full backward compatibility
- No breaking changes to existing API

### ⚠️ Breaking Changes
- None - all new features are opt-in via event listeners

### 📚 Migration Guide  
- Existing code works without changes
- Add event listeners for enhanced interruption handling
- Update TypeScript imports to include new event types

### 🧪 Testing
- Tested on iOS (iPad)
- Verified phone call interruptions
- Confirmed app backgrounding scenarios
- Android audio focus validation pending

---

## Upstream Compatibility
- Synced with upstream v7.0.5 (2024-08-19)
- All upstream features preserved
- Can be merged back to upstream with minor adjustments