;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2024 Giacomo Leidi <goodoldpaul@autistici.org>

(define-module (sops services databases)
  #:use-module (gnu)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages databases)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services databases)
  #:use-module (gnu services shepherd)
  #:use-module (sops secrets)
  #:use-module (sops services sops)
  #:use-module (srfi srfi-1)
  #:export (sops-secrets-postgresql-role
            sops-secrets-postgresql-role?
            sops-secrets-postgresql-role-fields
            sops-secrets-postgresql-role-password
            sops-secrets-postgresql-role-value

            sops-secrets-postgresql-role-configuration
            sops-secrets-postgresql-role-configuration?
            sops-secrets-postgresql-role-configuration-fields
            sops-secrets-postgresql-role-configuration-secrets-directory
            sops-secrets-postgresql-role-configuration-value

            sops-secrets-postgresql-set-passwords
            sops-secrets-postgresql-role-shepherd-service
            sops-secrets-postgresql-role-service-type))

(define-configuration/no-serialization sops-secrets-postgresql-role
  (password
   (sops-secret)
   "A sops-secret record representing the role password.")
  (value
   (postgresql-role)
   "The postgres-role record for the password."))

(define (list-of-sops-secrets-postgresql-roles? lst)
  (every sops-secrets-postgresql-role? lst))

(define-configuration/no-serialization sops-secrets-postgresql-role-configuration
  (secrets-directory
   (string "/run/secrets")
   "The path on the filesystem where the secrets are decrypted.")
  (value
   (list-of-sops-secrets-postgresql-roles '())
   "The sops-secrets-postgres-role records to provision."))

(define (sops-secrets-postgresql-set-passwords config)
  (define roles
    (sops-secrets-postgresql-role-configuration-value config))
  (define secrets-directory
    (sops-secrets-postgresql-role-configuration-secrets-directory config))
  (define (roles->queries roles)
    (apply mixed-text-file "sops-secrets-postgresql-set-passwords"
           (map
            (lambda (role)
              (let ((cat (file-append coreutils "/bin/cat"))
                    (psql (file-append postgresql "/bin/psql"))
                    (name (postgresql-role-name
                           (sops-secrets-postgresql-role-value role)))
                    (password
                     (sops-secrets-postgresql-role-password role)))
                #~(string-append #$psql " -c \""
                                 "ALTER ROLE " #$name " WITH PASSWORD "
                                 "'$(" #$cat " " #$secrets-directory "/"
                                 #$(sops-secret->file-name password) ")';\"\n")))
            roles)))

  #~(let ((bash #$(file-append bash-minimal "/bin/bash")))
      (list bash #$(roles->queries roles))))

(define (sops-secrets-postgresql-role-shepherd-service config)
  (list (shepherd-service
         (requirement '(postgres-roles sops-secrets))
         (provision '(sops-secrets-postgres-roles))
         (one-shot? #t)
         (start
          #~(lambda args
              (let ((pid (fork+exec-command
                          #$(sops-secrets-postgresql-set-passwords config)
                          #:user "postgres"
                          #:group "postgres")))
                (zero? (cdr (waitpid pid))))))
         (documentation "Set PostgreSQL roles passwords."))))

(define sops-secrets-postgresql-role-service-type
  (service-type (name 'sops-secrets-postgresql-role)
                (extensions
                 (list (service-extension shepherd-root-service-type
                                          sops-secrets-postgresql-role-shepherd-service)
                       (service-extension sops-secrets-service-type
                                          (lambda (config)
                                            (map sops-secrets-postgresql-role-password
                                                 (sops-secrets-postgresql-role-configuration-value config))))
                       (service-extension postgresql-role-service-type
                                          (lambda (config)
                                            (map sops-secrets-postgresql-role-value
                                                 (sops-secrets-postgresql-role-configuration-value config))))))
                (compose concatenate)
                (extend
                 (lambda (config roles)
                   (sops-secrets-postgresql-role-configuration
                    (inherit config)
                    (value
                     (append (sops-secrets-postgresql-role-configuration-value config)
                             roles)))))
                (default-value (sops-secrets-postgresql-role-configuration))
                (description "Ensure the specified PostgreSQL have a given password after they are
created.")))
