# frozen_string_literal: true

# name: unsub-update
# about: Postback when a user disables Activity Summary (digest) OR disables ALL email via checkbox, via Preferences UI or email unsubscribe flow.
# version: 1.2.0
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  module ::UnsubUpdateConfig
    ENABLED = true
    ENDPOINT_URL = "http://172.17.0.1:8081/unsub_update.php"
    MIN_MINUTES_SINCE_REGISTRATION = 5
    SHARED_SECRET = ""   # sent as form field "secret"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 5

    # Fire-once guard (per user per event) so you don’t spam endpoint
    # Set to false for testing to allow repeated postbacks.
    ENABLE_FIRE_ONCE_GUARD = false

    STORE_NAMESPACE = "unsub_update"

    # separate keys so each event can fire once independently
    STORE_KEY_DIGEST_PREFIX    = "sent_digest_never_user_" # + user_id
    STORE_KEY_ALLMAIL_PREFIX   = "sent_allmail_off_user_"  # + user_id
  end

  module ::UnsubUpdate
    # Digest "never" detection (your original)
    def self.digest_never?(opt)
      return false if opt.nil?
      opt.email_digests == false || opt.digest_after_minutes.to_i <= 0
    end

    # "Don’t send me any mail" checkbox:
    # In many Discourse versions this maps to user_option.email_level == 2 ("never").
    # We treat >= 2 as "off" to be tolerant if values expand.
    def self.all_mail_off?(opt)
      return false if opt.nil?
      return false unless opt.respond_to?(:email_level)
      opt.email_level.to_i >= 2
    end

    def self.user_too_new?(user)
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      user.created_at.present? && (Time.zone.now - user.created_at) < min_age
    end

    def self.store_key_for(event, user_id)
      uid = user_id.to_i
      case event.to_s
      when "digest_set_to_never"
        "#{::UnsubUpdateConfig::STORE_KEY_DIGEST_PREFIX}#{uid}"
      when "all_email_disabled"
        "#{::UnsubUpdateConfig::STORE_KEY_ALLMAIL_PREFIX}#{uid}"
      else
        "sent_unknown_#{event}_user_#{uid}"
      end
    end

    def self.already_sent?(event, user_id)
      return false unless ::UnsubUpdateConfig::ENABLE_FIRE_ONCE_GUARD
      PluginStore.get(::UnsubUpdateConfig::STORE_NAMESPACE, store_key_for(event, user_id)).to_s == "1"
    rescue => e
      Rails.logger.warn("[unsub-update] PluginStore get error event=#{event} user_id=#{user_id} err=#{e.class}: #{e.message}")
      false
    end

    def self.mark_sent!(event, user_id)
      return unless ::UnsubUpdateConfig::ENABLE_FIRE_ONCE_GUARD
      PluginStore.set(::UnsubUpdateConfig::STORE_NAMESPACE, store_key_for(event, user_id), "1")
    rescue => e
      Rails.logger.warn("[unsub-update] PluginStore set error event=#{event} user_id=#{user_id} err=#{e.class}: #{e.message}")
    end

    # Central gate: enqueue if state matches AND (optionally) not sent before.
    def self.maybe_enqueue_event(user, event:, source:)
      return unless ::UnsubUpdateConfig::ENABLED
      return if user.nil? || user.staged? || user.suspended?

      if user_too_new?(user)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{user.id} event=#{event} source=#{source}")
        return
      end

      opt = user.user_option

      should_fire =
        case event.to_s
        when "digest_set_to_never"
          digest_never?(opt)
        when "all_email_disabled"
          all_mail_off?(opt)
        else
          false
        end

      return unless should_fire

      if ::UnsubUpdateConfig::ENABLE_FIRE_ONCE_GUARD && already_sent?(event, user.id)
        Rails.logger.warn("[unsub-update] NOOP (already sent) user_id=#{user.id} event=#{event} source=#{source}")
        return
      end

      Rails.logger.warn("[unsub-update] ENQUEUE user_id=#{user.id} event=#{event} source=#{source} guard=#{::UnsubUpdateConfig::ENABLE_FIRE_ONCE_GUARD ? "on" : "off"}")
      ::Jobs.enqueue(:unsub_update_postback, user_id: user.id, event: event.to_s, source: source.to_s)
    rescue => e
      Rails.logger.warn("[unsub-update] maybe_enqueue_event error user_id=#{user&.id} event=#{event} source=#{source} err=#{e.class}: #{e.message}")
    end

    # After a user-facing action, check BOTH states and enqueue whichever applies.
    def self.check_and_enqueue_all(user, source:)
      return if user.nil?
      user.reload

      maybe_enqueue_event(user, event: "digest_set_to_never", source: source)
      maybe_enqueue_event(user, event: "all_email_disabled",  source: source)
    rescue => e
      Rails.logger.warn("[unsub-update] check_and_enqueue_all error user_id=#{user&.id} source=#{source} err=#{e.class}: #{e.message}")
    end
  end

  class ::Jobs::UnsubUpdatePostback < ::Jobs::Base
    def execute(args)
      return unless ::UnsubUpdateConfig::ENABLED

      user = User.find_by(id: args[:user_id].to_i)
      return if user.nil? || user.staged? || user.suspended?

      if ::UnsubUpdate.user_too_new?(user)
        Rails.logger.warn("[unsub-update] JOB SKIP (too new) user_id=#{user.id}")
        return
      end

      event = args[:event].to_s.presence || "digest_set_to_never"

      opt = user.user_option

      # Must still match the event state at execution time
      still_valid =
        case event
        when "digest_set_to_never"
          ::UnsubUpdate.digest_never?(opt)
        when "all_email_disabled"
          ::UnsubUpdate.all_mail_off?(opt)
        else
          false
        end

      return unless still_valid

      if ::UnsubUpdateConfig::ENABLE_FIRE_ONCE_GUARD && ::UnsubUpdate.already_sent?(event, user.id)
        Rails.logger.warn("[unsub-update] JOB NOOP (already sent) user_id=#{user.id} event=#{event}")
        return
      end

      payload = {
        "event" => event,
        "user_id" => user.id.to_s,
        "username" => user.username.to_s,
        "email" => user.email.to_s,
        "registered_at" => (user.created_at&.utc&.iso8601 || ""),
        "sent_at_utc" => Time.zone.now.utc.iso8601,
        "secret" => ::UnsubUpdateConfig::SHARED_SECRET,
        "source" => args[:source].to_s,
        "guard" => (::UnsubUpdateConfig::ENABLE_FIRE_ONCE_GUARD ? "on" : "off"),

        # extra diagnostics (harmless for your PHP side; ignore if you want)
        "email_level" => (opt.respond_to?(:email_level) ? opt.email_level.to_i.to_s : ""),
        "email_messages_level" => (opt.respond_to?(:email_messages_level) ? opt.email_messages_level.to_i.to_s : ""),
        "email_digests" => (opt&.email_digests.nil? ? "" : opt.email_digests ? "1" : "0"),
        "digest_after_minutes" => opt&.digest_after_minutes.to_i.to_s
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
          ::UnsubUpdate.mark_sent!(event, user.id)
          Rails.logger.warn("[unsub-update] POST OK user_id=#{user.id} event=#{event} code=#{code}")
        else
          Rails.logger.warn("[unsub-update] POST FAILED user_id=#{user.id} event=#{event} code=#{code} body=#{resp.body.to_s[0, 500]}")
        end
      rescue => e
        Rails.logger.warn("[unsub-update] POST ERROR user_id=#{user.id} event=#{event} err=#{e.class}: #{e.message}")
      end
    end
  end

  # ============================================================
  # ✅ HOOK 1: Preferences UI save path (logged-in user)
  # ============================================================
  if defined?(::Users::PreferencesController)
    class ::Users::PreferencesController
      module ::UnsubUpdateUsersPreferencesControllerHook
        def update
          return super unless ::UnsubUpdateConfig::ENABLED

          # Run Discourse behavior first (we do not alter it)
          result = super

          begin
            user = nil
            user = instance_variable_get(:@user) rescue nil
            user ||= (respond_to?(:current_user) ? current_user : nil)

            ::UnsubUpdate.check_and_enqueue_all(user, source: "users_preferences_update")
          rescue => e
            Rails.logger.warn("[unsub-update] Users::PreferencesController hook error err=#{e.class}: #{e.message}")
          end

          result
        end
      end

      prepend ::UnsubUpdateUsersPreferencesControllerHook
    end
  else
    Rails.logger.warn("[unsub-update] Users::PreferencesController not defined; prefs UI hook not installed")
  end

  # ============================================================
  # ✅ HOOK 2: Email unsubscribe flow
  # ============================================================
  class ::EmailController
    module ::UnsubUpdateEmailHook
      def unsubscribe
        return super unless ::UnsubUpdateConfig::ENABLED
        result = super

        begin
          user = resolve_user_from_unsub_key(params[:key])
          ::UnsubUpdate.check_and_enqueue_all(user, source: "email_unsubscribe")
        rescue => e
          Rails.logger.warn("[unsub-update] EMAIL unsubscribe hook error err=#{e.class}: #{e.message}")
        end

        result
      end

      # Some Discourse versions do the actual state change here.
      def perform_unsubscribe
        return super unless ::UnsubUpdateConfig::ENABLED
        result = super

        begin
          user = resolve_user_from_unsub_key(params[:key])
          ::UnsubUpdate.check_and_enqueue_all(user, source: "email_perform_unsubscribe")
        rescue => e
          Rails.logger.warn("[unsub-update] EMAIL perform_unsubscribe hook error err=#{e.class}: #{e.message}")
        end

        result
      end

      private

      def resolve_user_from_unsub_key(key)
        return nil if key.blank?
        return nil unless defined?(::UnsubscribeKey)

        k = ::UnsubscribeKey.includes(:user).find_by(key: key.to_s)
        k&.user
      rescue => e
        Rails.logger.warn("[unsub-update] EMAIL resolve key error err=#{e.class}: #{e.message}")
        nil
      end
    end

    prepend ::UnsubUpdateEmailHook
  end
end
