# frozen_string_literal: true

# name: unsub-update
# about: When a user sets Activity Summary (digest) to "Never" (email_digests=false OR digest_after_minutes<=0) and they registered >10 minutes ago, send an async POST.
# version: 1.0.2
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  module ::UnsubUpdateConfig
    ENABLED = true
    ENDPOINT_URL = "https://ai.templetrends.com/unsub_update.php"
    MIN_MINUTES_SINCE_REGISTRATION = 10
    SHARED_SECRET = ""   # sent as form field "secret"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10
  end

  def self._unsub_never?(user_option)
    return false if user_option.nil?
    user_option.email_digests == false || user_option.digest_after_minutes.to_i <= 0
  end

  class ::Jobs::UnsubUpdatePostback < ::Jobs::Base
    def execute(args)
      return unless ::UnsubUpdateConfig::ENABLED

      user = User.find_by(id: args[:user_id].to_i)
      return if user.nil? || user.staged? || user.suspended?

      opt = user.user_option
      return unless ::UnsubUpdate._unsub_never?(opt) rescue (opt && (opt.email_digests == false || opt.digest_after_minutes.to_i <= 0))

      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      return if user.created_at.present? && (Time.zone.now - user.created_at) < min_age

      payload = {
        "event" => "digest_set_to_never",
        "user_id" => user.id.to_s,
        "username" => user.username.to_s,
        "email" => user.email.to_s,
        "registered_at" => (user.created_at&.utc&.iso8601 || ""),
        "email_digests" => (opt&.email_digests.nil? ? "" : opt.email_digests ? "1" : "0"),
        "digest_after_minutes" => opt&.digest_after_minutes.to_i.to_s,
        "sent_at_utc" => Time.zone.now.utc.iso8601,
        "secret" => ::UnsubUpdateConfig::SHARED_SECRET
      }

      uri = URI(::UnsubUpdateConfig::ENDPOINT_URL)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = ::UnsubUpdateConfig::OPEN_TIMEOUT_SECONDS
      http.read_timeout = ::UnsubUpdateConfig::READ_TIMEOUT_SECONDS

      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(payload)

      begin
        resp = http.request(req)
        code = resp.code.to_i
        if code >= 200 && code < 300
          Rails.logger.warn("[unsub-update] POST OK user_id=#{user.id} code=#{code}")
        else
          Rails.logger.warn("[unsub-update] POST FAILED user_id=#{user.id} code=#{code} body=#{resp.body.to_s[0, 500]}")
        end
      rescue => e
        Rails.logger.warn("[unsub-update] POST ERROR user_id=#{user.id} err=#{e.class}: #{e.message}")
      end
    end
  end

  UserOption.class_eval do
    after_commit :_unsub_update_after_commit, on: [:update]

    def _unsub_update_after_commit
      return unless ::UnsubUpdateConfig::ENABLED

      # Detect either field changed (because "Never" may flip email_digests, not digest_after_minutes)
      changed =
        (respond_to?(:saved_change_to_email_digests?) && saved_change_to_email_digests?) ||
        (respond_to?(:saved_change_to_digest_after_minutes?) && saved_change_to_digest_after_minutes?) ||
        (previous_changes.key?("email_digests") || previous_changes.key?("digest_after_minutes"))

      return unless changed

      # Only trigger when state is "never"
      return unless (email_digests == false || digest_after_minutes.to_i <= 0)

      u = self.user
      return if u.nil?

      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      if u.created_at.present? && (Time.zone.now - u.created_at) < min_age
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{u.id}")
        return
      end

      Rails.logger.warn("[unsub-update] ENQUEUE user_id=#{u.id} email_digests=#{email_digests.inspect} digest_after_minutes=#{digest_after_minutes.inspect}")
      ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
    end
  end
end
