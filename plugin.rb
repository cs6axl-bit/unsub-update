# frozen_string_literal: true

# name: unsub-update
# about: Postback when a user sets Activity Summary (digest) to "Never" via prefs/API OR via email unsubscribe flow.
#        ALSO: if user checks "Don’t send me any mail" (global email off), force digest to Never too.
# version: 1.1.0
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  module ::UnsubUpdateConfig
    ENABLED = true
    ENDPOINT_URL = "http://172.17.0.1:8081/unsub_update.php"
    MIN_MINUTES_SINCE_REGISTRATION = 2
    SHARED_SECRET = ""   # sent as form field "secret"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 5
  end

  module ::UnsubUpdate
    # Thread-local guard to avoid infinite loops when we modify UserOption inside callbacks.
    def self.guard_key
      :_unsub_update_guard
    end

    def self.with_guard
      Thread.current[guard_key] ||= 0
      Thread.current[guard_key] += 1
      yield
    ensure
      Thread.current[guard_key] -= 1
    end

    def self.guarded?
      Thread.current[guard_key].to_i > 0
    end

    def self.unsub_never?(user_option)
      return false if user_option.nil?
      user_option.email_digests == false || user_option.digest_after_minutes.to_i <= 0
    end

    # This is the "Don’t send me any mail" checkbox behavior (global email off).
    # In Discourse this is typically user_option.email_level == UserOption.email_level_types[:never]
    def self.no_mail_enabled?(user_option)
      return false if user_option.nil?

      types = if user_option.class.respond_to?(:email_level_types)
        user_option.class.email_level_types
      else
        {}
      end

      never_val = types[:never]
      return false if never_val.nil?

      user_option.email_level.to_i == never_val.to_i
    end

    def self.user_too_new?(user)
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      user.created_at.present? && (Time.zone.now - user.created_at) < min_age
    end

    # Force digest to Never (so behavior matches your desired meaning of "no mail at all").
    # Uses update_columns to avoid triggering validations; we still rely on our own enqueue.
    def self.force_digest_never!(user_option)
      return false if user_option.nil?

      needs_change =
        (user_option.email_digests != false) ||
        (user_option.digest_after_minutes.to_i > 0)

      return false unless needs_change

      user_option.update_columns(
        email_digests: false,
        digest_after_minutes: 0,
        updated_at: Time.zone.now
      )
      true
    end
  end

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

  # -----------------------------
  # 1) Trigger on prefs/API changes (normal path)
  # -----------------------------
  UserOption.class_eval do
    after_commit :_unsub_update_after_commit, on: [:update]

    def _unsub_update_after_commit
      return unless ::UnsubUpdateConfig::ENABLED
      return if ::UnsubUpdate.guarded?

      # Detect changes (digest dropdown OR global email off checkbox)
      changed_digest =
        (respond_to?(:saved_change_to_email_digests?) && saved_change_to_email_digests?) ||
        (respond_to?(:saved_change_to_digest_after_minutes?) && saved_change_to_digest_after_minutes?) ||
        (previous_changes.key?("email_digests") || previous_changes.key?("digest_after_minutes"))

      changed_email_level =
        (respond_to?(:saved_change_to_email_level?) && saved_change_to_email_level?) ||
        previous_changes.key?("email_level")

      u = self.user
      return if u.nil?
      return if u.staged? || u.suspended?

      if ::UnsubUpdate.user_too_new?(u)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{u.id}")
        return
      end

      ::UnsubUpdate.with_guard do
        # If user turned on "no mail", force digest to never
        if changed_email_level && ::UnsubUpdate.no_mail_enabled?(self)
          did_force = ::UnsubUpdate.force_digest_never!(self)
          Rails.logger.warn(
            "[unsub-update] NO-MAIL -> FORCE DIGEST NEVER user_id=#{u.id} forced=#{did_force ? 1 : 0} source=user_option_update"
          )
          # Always enqueue postback after no-mail, because meaning becomes digest never.
          ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
          return
        end

        # Regular digest set-to-never path
        return unless changed_digest
        return unless ::UnsubUpdate.unsub_never?(self)

        Rails.logger.warn(
          "[unsub-update] ENQUEUE user_id=#{u.id} email_digests=#{email_digests.inspect} digest_after_minutes=#{digest_after_minutes.inspect} source=user_option_update"
        )
        ::Jobs.enqueue(:unsub_update_postback, user_id: u.id)
      end
    end
  end

  # -----------------------------
  # 2) Trigger on email unsubscribe clicks (/email/unsubscribe/:key)
  #    This catches cases where Discourse bypasses UserOption callbacks.
  # -----------------------------
  class ::EmailController
    module ::UnsubUpdateEmailUnsubscribeHook
      def unsubscribe
        super

        return unless ::UnsubUpdateConfig::ENABLED

        # Best-effort: resolve user from key (works even if controller ivars change)
        user = nil
        begin
          if defined?(::UnsubscribeKey)
            k = ::UnsubscribeKey.includes(:user).find_by(key: params[:key].to_s)
            user = k&.user
          end
        rescue => e
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB resolve key error err=#{e.class}: #{e.message}")
        end

        return if user.nil? || user.staged? || user.suspended?

        if ::UnsubUpdate.user_too_new?(user)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB SKIP (too new) user_id=#{user.id}")
          return
        end

        opt = user.user_option

        ::UnsubUpdate.with_guard do
          # If unsubscribe flow resulted in "no mail", force digest never too
          if ::UnsubUpdate.no_mail_enabled?(opt)
            did_force = ::UnsubUpdate.force_digest_never!(opt)
            Rails.logger.warn("[unsub-update] EMAIL-UNSUB NO-MAIL -> FORCE DIGEST NEVER user_id=#{user.id} forced=#{did_force ? 1 : 0}")
            ::Jobs.enqueue(:unsub_update_postback, user_id: user.id)
            return
          end

          # Otherwise: keep old behavior (only enqueue if digest is now never)
          unless ::UnsubUpdate.unsub_never?(opt)
            Rails.logger.warn("[unsub-update] EMAIL-UNSUB no-op user_id=#{user.id} (digest not set to never)")
            return
          end

          Rails.logger.warn("[unsub-update] EMAIL-UNSUB ENQUEUE user_id=#{user.id}")
          ::Jobs.enqueue(:unsub_update_postback, user_id: user.id)
        end
      end
    end

    prepend ::UnsubUpdateEmailUnsubscribeHook
  end
end
