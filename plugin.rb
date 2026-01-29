# frozen_string_literal: true

# name: unsub-update
# about: When a user sets Activity Summary (digest) to "Never" and they registered >10 minutes ago, send an async POST to an external endpoint.
# version: 1.0.3
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  # ============================================================
  # CONFIG (EDIT HERE)
  # ============================================================
  module ::UnsubUpdateConfig
    ENABLED = true

    # Your external endpoint (PHP)
    ENDPOINT_URL = "https://ai.templetrends.com/unsub_update.php"

    # Only send if user registered >= this many minutes ago
    MIN_MINUTES_SINCE_REGISTRATION = 10

    # Optional shared secret for your PHP endpoint (sent as form field)
    SHARED_SECRET = ""

    # Timeouts
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10
  end

  # ============================================================
  # JOB: sends POST in Sidekiq (async, non-blocking)
  # ============================================================
  class ::Jobs::UnsubUpdatePostback < ::Jobs::Base
    def execute(args)
      return unless ::UnsubUpdateConfig::ENABLED

      user_id = args[:user_id].to_i
      user = User.find_by(id: user_id)
      return if user.nil?
      return if user.staged? || user.suspended?

      opt = user.user_option
      return if opt.nil?

      # Only proceed if digest is STILL "never"
      return unless opt.digest_after_minutes.to_i <= 0

      # If user registered < MIN minutes ago => DO NOTHING
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      return if user.created_at.present? && (Time.zone.now - user.created_at) < min_age

      payload = {
        "event" => "digest_set_to_never",
        "user_id" => user.id.to_s,
        "username" => user.username.to_s,
        "email" => user.email.to_s,
        "registered_at" => (user.created_at&.utc&.iso8601 || ""),
        "digest_after_minutes" => opt.digest_after_minutes.to_i.to_s,
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
        if code < 200 || code >= 300
          Rails.logger.warn("[unsub-update] POST failed user_id=#{user.id} code=#{code} body=#{resp.body.to_s[0, 500]}")
        end
      rescue => e
        Rails.logger.warn("[unsub-update] POST error user_id=#{user.id} err=#{e.class}: #{e.message}")
      end
    end
  end

  # ============================================================
  # HOOK: detect when digest is changed to "Never"
  # ============================================================
  UserOption.class_eval do
    after_commit :_unsub_update_after_commit, on: [:update]

    def _unsub_update_after_commit
      return unless ::UnsubUpdateConfig::ENABLED

      # Only react when digest_after_minutes changed
      return unless saved_change_to_digest_after_minutes?

      # "Never" is stored as 0 (or <=0)
      return unless digest_after_minutes.to_i <= 0

      u = self.user
      return if u.nil?

      # If user is < MIN minutes old => do nothing
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      return if u.created_at.present? && (Time.zone.now - u.created_at) < min_age

      ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
    end
  end
end
