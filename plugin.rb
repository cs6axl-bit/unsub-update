# frozen_string_literal: true

# name: unsub-update
# about: Postback when a user sets Activity Summary (digest) to "Never" via prefs/API OR via email unsubscribe flow.
# version: 1.0.3
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  # -----------------------------
  # Config
  # -----------------------------
  module ::UnsubUpdateConfig
    ENABLED = true

    # Your PHP endpoint (host-side, reached from inside the Discourse container)
    ENDPOINT_URL = "http://172.17.0.1:8081/unsub_update.php"

    # Avoid noisy postbacks for brand-new registrations
    MIN_MINUTES_SINCE_REGISTRATION = 2

    # Sent as form field "secret"
    SHARED_SECRET = ""

    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 5
  end

  # -----------------------------
  # Helpers
  # -----------------------------
  module ::UnsubUpdate
    def self.unsub_never?(user_option)
      return false if user_option.nil?

      # Discourse typically represents "never" as digest_after_minutes <= 0.
      # Some installs also set email_digests=false.
      user_option.email_digests == false || user_option.digest_after_minutes.to_i <= 0
    end

    def self.user_too_new?(user)
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      user.created_at.present? && (Time.zone.now - user.created_at) < min_age
    end
  end

  # -----------------------------
  # Job: send postback
  # -----------------------------
  class ::Jobs::UnsubUpdatePostback < ::Jobs::Base
    def execute(args)
      return unless ::UnsubUpdateConfig::ENABLED

      user = User.find_by(id: args[:user_id].to_i)
      return if user.nil? || user.staged? || user.suspended?

      opt = user.user_option
      return unless ::UnsubUpdate.unsub_never?(opt)

      if ::UnsubUpdate.user_too_new?(user)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{user.id}")
        return
      end

      payload = build_payload(user, opt)

      begin
        resp = http_post_form(::UnsubUpdateConfig::ENDPOINT_URL, payload)
        code = resp.code.to_i

        if code.between?(200, 299)
          Rails.logger.warn("[unsub-update] POST OK user_id=#{user.id} code=#{code}")
        else
          Rails.logger.warn(
            "[unsub-update] POST FAILED user_id=#{user.id} code=#{code} body=#{resp.body.to_s[0, 500]}"
          )
        end
      rescue => e
        Rails.logger.warn("[unsub-update] POST ERROR user_id=#{user.id} err=#{e.class}: #{e.message}")
      end
    end

    private

    def build_payload(user, opt)
      {
        "event" => "digest_set_to_never",
        "user_id" => user.id.to_s,
        "username" => user.username.to_s,
        "email" => user.email.to_s,
        "registered_at" => (user.created_at&.utc&.iso8601 || ""),
        "email_digests" => opt&.email_digests.nil? ? "" : (opt.email_digests ? "1" : "0"),
        "digest_after_minutes" => opt&.digest_after_minutes.to_i.to_s,
        "sent_at_utc" => Time.zone.now.utc.iso8601,
        "secret" => ::UnsubUpdateConfig::SHARED_SECRET
      }
    end

    def http_post_form(url, form_hash)
      uri = URI(url)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = ::UnsubUpdateConfig::OPEN_TIMEOUT_SECONDS
      http.read_timeout = ::UnsubUpdateConfig::READ_TIMEOUT_SECONDS

      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(form_hash)

      http.request(req)
    end
  end

  # -----------------------------
  # 1) Trigger on prefs/API changes (normal path)
  # -----------------------------
  UserOption.class_eval do
    after_commit :_unsub_update_after_commit, on: [:update]

    def _unsub_update_after_commit
      return unless ::UnsubUpdateConfig::ENABLED

      changed =
        (respond_to?(:saved_change_to_email_digests?) && saved_change_to_email_digests?) ||
        (respond_to?(:saved_change_to_digest_after_minutes?) && saved_change_to_digest_after_minutes?) ||
        previous_changes.key?("email_digests") ||
        previous_changes.key?("digest_after_minutes")

      return unless changed
      return unless ::UnsubUpdate.unsub_never?(self)

      u = user
      return if u.nil?

      if ::UnsubUpdate.user_too_new?(u)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{u.id}")
        return
      end

      Rails.logger.warn(
        "[unsub-update] ENQUEUE user_id=#{u.id} email_digests=#{email_digests.inspect} " \
        "digest_after_minutes=#{digest_after_minutes.inspect} source=user_option_update"
      )

      ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
    end
  end

  # -----------------------------
  # 2) Trigger on email unsubscribe clicks (/email/unsubscribe/:key)
  # Some unsubscribe flows can bypass the UserOption callbacks, so hook controller too.
  # -----------------------------
  class ::EmailController
    module ::UnsubUpdateEmailUnsubscribeHook
      def unsubscribe
        super

        return unless ::UnsubUpdateConfig::ENABLED

        user = resolve_user_from_unsub_key(params[:key].to_s)
        return if user.nil? || user.staged? || user.suspended?

        opt = user.user_option
        unless ::UnsubUpdate.unsub_never?(opt)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB no-op user_id=#{user.id} (digest not set to never)")
          return
        end

        if ::UnsubUpdate.user_too_new?(user)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB SKIP (too new) user_id=#{user.id}")
          return
        end

        Rails.logger.warn("[unsub-update] EMAIL-UNSUB ENQUEUE user_id=#{user.id}")
        ::Jobs.enqueue(:unsub_update_postback, user_id: user.id)
      end

      private

      def resolve_user_from_unsub_key(key)
        return nil unless defined?(::UnsubscribeKey)

        begin
          k = ::UnsubscribeKey.includes(:user).find_by(key: key)
          k&.user
        rescue => e
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB resolve key error err=#{e.class}: #{e.message}")
          nil
        end
      end
    end

    prepend ::UnsubUpdateEmailUnsubscribeHook
  end
end
