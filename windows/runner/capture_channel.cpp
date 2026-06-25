#include "capture_channel.h"

#include <flutter/standard_method_codec.h>

#include <utility>

CaptureChannel::CaptureChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "glimpr/capture",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

CaptureChannel::~CaptureChannel() = default;

void CaptureChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Placeholder until the capture methods land (S2a Task 2+).
  result->NotImplemented();
}
