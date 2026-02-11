# frozen_string_literal: true

# name: unsub-update
# about: Postback when a user sets digest to "Never" via prefs/API. UI: ticking unsubscribe_all sets digest dropdown to never.
# version: 1.1.2
# authors: you

after_initialize do
  require "net/http"
  require "uri"
  require "json"

  module ::UnsubUpdateConfig
    ENABLED = true
    ENDPOINT_URL = "http://172.17.0.1:8081/unsub_update.php"
    MIN_MINUTES_SINCE_REGISTRATION = 2
    SHARED_SECRET = ""
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 5

    UI_DISABLE_DIGEST_DROPDOWN_WHEN_UNSUB_ALL = true

    # Keep safe: do NOT force digest based on email_level changes.
    FORCE_DIGEST_NEVER_WHEN_EMAIL_LEVEL_NEVER = false
    POSTBACK_ON_EMAIL_LEVEL_NEVER = true

    # Only run unsubscribe controller hook on POST, not page view.
    EMAIL_UNSUB_HOOK_ONLY_ON_POST = true
  end

  module ::UnsubUpdate
    def self.unsub_never?(user_option)
      return false if user_option.nil?
      user_option.email_digests == false || user_option.digest_after_minutes.to_i <= 0
    end

    def self.user_too_new?(user)
      min_age = ::UnsubUpdateConfig::MIN_MINUTES_SINCE_REGISTRATION.to_i.minutes
      user.created_at.present? && (Time.zone.now - user.created_at) < min_age
    end

    def self.no_mail_enabled?(user_option)
      return false if user_option.nil?
      return false unless user_option.respond_to?(:email_level)

      types =
        if user_option.class.respond_to?(:email_level_types)
          user_option.class.email_level_types
        else
          {}
        end

      never_val = types[:never]
      return false if never_val.nil?

      user_option.email_level.to_i == never_val.to_i
    end

    def self.force_digest_never!(user_option)
      return false if user_option.nil?

      needs_change =
        (user_option.email_digests != false) ||
        (user_option.digest_after_minutes.to_i > 0)

      return false unless needs_change

      user_option.update_columns(
        email_digests: false,
        digest_after_minutes: 0
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
      event = args[:event].to_s.presence || "digest_set_to_never"

      if event == "digest_set_to_never"
        return unless ::UnsubUpdate.unsub_never?(opt)
      elsif event == "email_level_set_to_never"
        return unless ::UnsubUpdate.no_mail_enabled?(opt)
      end

      if ::UnsubUpdate.user_too_new?(user)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{user.id} event=#{event}")
        return
      end

      payload = {
        "event" => event,
        "user_id" => user.id.to_s,
        "username" => user.username.to_s,
        "email" => user.email.to_s,
        "registered_at" => (user.created_at&.utc&.iso8601 || ""),
        "email_level" => (opt&.respond_to?(:email_level) ? opt.email_level.to_i.to_s : ""),
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
          Rails.logger.warn("[unsub-update] POST OK user_id=#{user.id} event=#{event} code=#{code}")
        else
          Rails.logger.warn("[unsub-update] POST FAILED user_id=#{user.id} event=#{event} code=#{code} body=#{resp.body.to_s[0, 500]}")
        end
      rescue => e
        Rails.logger.warn("[unsub-update] POST ERROR user_id=#{user.id} event=#{event} err=#{e.class}: #{e.message}")
      end
    end
  end

  # 1) Trigger on prefs/API changes
  UserOption.class_eval do
    after_commit :_unsub_update_after_commit, on: [:update]

    def _unsub_update_after_commit
      return unless ::UnsubUpdateConfig::ENABLED

      changed_digest =
        (respond_to?(:saved_change_to_email_digests?) && saved_change_to_email_digests?) ||
        (respond_to?(:saved_change_to_digest_after_minutes?) && saved_change_to_digest_after_minutes?) ||
        (previous_changes.key?("email_digests") || previous_changes.key?("digest_after_minutes"))

      changed_email_level =
        (respond_to?(:saved_change_to_email_level?) && saved_change_to_email_level?) ||
        previous_changes.key?("email_level")

      return unless (changed_digest || changed_email_level)

      u = self.user
      return if u.nil? || u.staged? || u.suspended?

      if ::UnsubUpdate.user_too_new?(u)
        Rails.logger.warn("[unsub-update] SKIP (too new) user_id=#{u.id}")
        return
      end

      if changed_email_level && ::UnsubUpdate.no_mail_enabled?(self)
        if ::UnsubUpdateConfig::FORCE_DIGEST_NEVER_WHEN_EMAIL_LEVEL_NEVER
          forced = ::UnsubUpdate.force_digest_never!(self)
          Rails.logger.warn("[unsub-update] NO-MAIL -> FORCE DIGEST NEVER user_id=#{u.id} forced=#{forced ? 1 : 0} source=user_option_update")
          ::Jobs.enqueue(:unsub_update_postback, user_id: u.id, event: "digest_set_to_never")
        end

        if ::UnsubUpdateConfig::POSTBACK_ON_EMAIL_LEVEL_NEVER
          Rails.logger.warn("[unsub-update] ENQUEUE email_level_set_to_never user_id=#{u.id} source=user_option_update")
          ::Jobs.enqueue(:unsub_update_postback, user_id: u.id, event: "email_level_set_to_never")
        end
      end

      return unless changed_digest
      return unless ::UnsubUpdate.unsub_never?(self)

      Rails.logger.warn("[unsub-update] ENQUEUE digest_set_to_never user_id=#{u.id} source=user_option_update")
      ::Jobs.enqueue(:unsub_update_postback, user_id: u.id, event: "digest_set_to_never")
    end
  end

  # 2) Trigger on unsubscribe submit (/email/unsubscribe/:key) — POST only
  class ::EmailController
    module ::UnsubUpdateEmailUnsubscribeHook
      def unsubscribe
        super

        return unless ::UnsubUpdateConfig::ENABLED
        if ::UnsubUpdateConfig::EMAIL_UNSUB_HOOK_ONLY_ON_POST
          return unless (respond_to?(:request) && request&.post?)
        end

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

        opt = user.reload.user_option

        if ::UnsubUpdate.unsub_never?(opt)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB ENQUEUE digest_set_to_never user_id=#{user.id}")
          ::Jobs.enqueue(:unsub_update_postback, user_id: user.id, event: "digest_set_to_never")
        end

        if ::UnsubUpdateConfig::POSTBACK_ON_EMAIL_LEVEL_NEVER && ::UnsubUpdate.no_mail_enabled?(opt)
          Rails.logger.warn("[unsub-update] EMAIL-UNSUB ENQUEUE email_level_set_to_never user_id=#{user.id}")
          ::Jobs.enqueue(:unsub_update_postback, user_id: user.id, event: "email_level_set_to_never")
        end
      rescue => e
        Rails.logger.warn("[unsub-update] EMAIL-UNSUB HOOK ERROR err=#{e.class}: #{e.message}")
        nil
      end
    end

    prepend ::UnsubUpdateEmailUnsubscribeHook
  end

  # 3) UI injection — move to HEAD and use robust selectors
  begin
    js_disable_dropdown = ::UnsubUpdateConfig::UI_DISABLE_DIGEST_DROPDOWN_WHEN_UNSUB_ALL ? "true" : "false"

    register_html_builder("server:before-head-close") do |_ctx|
      <<~HTML
        <script>
        (function(){
          try {
            var DISABLE = #{js_disable_dropdown};

            function isUnsubPage(){
              var p = (location && location.pathname) ? location.pathname : "";
              return p.indexOf("/email/unsubscribe/") === 0;
            }

            function q(sel){ try { return document.querySelector(sel); } catch(e){ return null; } }

            function findCheckbox(){
              // try common ids and names
              return q("#unsubscribe_all") ||
                     q("input[name='unsubscribe_all']") ||
                     q("input#user_option_unsubscribe_all") ||
                     q("input[name='user_option[unsubscribe_all]']");
            }

            function findDigestSelect(){
              return q("#digest_after_minutes") ||
                     q("select[name='digest_after_minutes']") ||
                     q("select#user_option_digest_after_minutes") ||
                     q("select[name='user_option[digest_after_minutes]']");
            }

            function setNever(dd){
              if (!dd) return false;
              var v = "0";
              if (dd.value !== v) {
                dd.value = v;
                try { dd.dispatchEvent(new Event("change", {bubbles:true})); } catch(e) {}
                try { dd.dispatchEvent(new Event("input", {bubbles:true})); } catch(e) {}
              }
              return true;
            }

            function bindOnce(){
              if (!isUnsubPage()) return true;

              var cb = findCheckbox();
              var dd = findDigestSelect();

              // If no select exists yet, keep trying.
              if (!dd) return false;

              // If no checkbox exists on this variant, nothing to do.
              if (!cb) return true;

              if (cb.__unsubUpdateBound) return true;
              cb.__unsubUpdateBound = true;

              cb.addEventListener("change", function(){
                if (cb.checked) {
                  setNever(dd);
                  if (DISABLE) dd.disabled = true;
                } else {
                  if (DISABLE) dd.disabled = false;
                }
              });

              return true;
            }

            function start(){
              // immediate attempt
              bindOnce();

              // retry loop (covers late DOM)
              var tries = 0;
              var iv = setInterval(function(){
                tries++;
                if (bindOnce() || tries >= 80) clearInterval(iv);
              }, 100);

              // mutation observer (covers DOM changes)
              try {
                var mo = new MutationObserver(function(){ bindOnce(); });
                mo.observe(document.documentElement, {subtree:true, childList:true});
                setTimeout(function(){ try{ mo.disconnect(); }catch(e){} }, 15000);
              } catch(e) {}
            }

            if (document.readyState === "loading") {
              document.addEventListener("DOMContentLoaded", start);
            } else {
              start();
            }
          } catch(e) {}
        })();
        </script>
      HTML
    end
  rescue => e
    Rails.logger.warn("[unsub-update] UI inject error err=#{e.class}: #{e.message}")
  end
end
