// Copyright (c) 2019 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.daml.ledger.api.server.damlonx.reference.v2

import java.util.concurrent.atomic.AtomicBoolean

import akka.actor.ActorSystem
import akka.stream.{ActorMaterializer, ActorMaterializerSettings, Supervision}
import com.codahale.metrics.SharedMetricRegistries
import com.daml.ledger.api.server.damlonx.reference.v2.cli.Cli
import com.daml.ledger.participant.state.kvutils.InMemoryKVParticipantState
import com.digitalasset.daml.lf.archive.DarReader
import com.digitalasset.daml_lf_dev.DamlLf.Archive
import com.digitalasset.ledger.api.auth.AuthServiceWildcard
import com.digitalasset.platform.common.logging.NamedLoggerFactory
import com.digitalasset.platform.index.config.Config
import com.digitalasset.platform.index.{StandaloneIndexServer, StandaloneIndexerServer}
import org.slf4j.LoggerFactory

import scala.concurrent.{ExecutionContext, Future}
import scala.util.Try
import scala.util.control.NonFatal

object ReferenceServer extends App {
  val logger = LoggerFactory.getLogger("indexed-kvutils")

  val config =
    Cli
      .parse(
        args,
        "damlonx-reference-server",
        "A fully compliant DAML Ledger API server backed by an in-memory store.",
        allowExtraParticipants = true)
      .getOrElse(sys.exit(1))

  implicit val system: ActorSystem = ActorSystem("indexed-kvutils")
  implicit val materializer: ActorMaterializer = ActorMaterializer(
    ActorMaterializerSettings(system)
      .withSupervisionStrategy { e =>
        logger.error(s"Supervision caught exception: $e")
        Supervision.Stop
      })
  implicit val ec: ExecutionContext = system.dispatcher

  val ledger = new InMemoryKVParticipantState(config.participantId)

  val readService = ledger
  val writeService = ledger
  val authService = AuthServiceWildcard

  config.archiveFiles.foreach { file =>
    for {
      dar <- DarReader { case (_, x) => Try(Archive.parseFrom(x)) }
        .readArchiveFromFile(file)
    } yield ledger.uploadPackages(dar.all, None)
  }

  val participantF: Future[(AutoCloseable, StandaloneIndexServer#SandboxState)] = for {
    indexerServer <- newIndexer(config)
    indexServer <- newIndexServer(config).start()
  } yield (indexerServer, indexServer)

  val extraParticipants =
    for {
      (extraParticipantId, port, jdbcUrl) <- config.extraParticipants
    } yield {
      val participantConfig = config.copy(
        port = port,
        participantId = extraParticipantId,
        jdbcUrl = jdbcUrl,
      )
      for {
        extraIndexer <- newIndexer(participantConfig)
        extraLedgerApiServer <- newIndexServer(participantConfig).start()
      } yield (extraIndexer, extraLedgerApiServer)
    }

  def newIndexer(config: Config) =
    StandaloneIndexerServer(
      readService,
      config,
      NamedLoggerFactory.forParticipant(config.participantId),
      SharedMetricRegistries.getOrCreate(s"indexer-${config.participantId}"),
    )

  def newIndexServer(config: Config) =
    new StandaloneIndexServer(
      config,
      readService,
      writeService,
      authService,
      NamedLoggerFactory.forParticipant(config.participantId),
      SharedMetricRegistries.getOrCreate(s"ledger-api-server-${config.participantId}"),
    )

  val closed = new AtomicBoolean(false)

  def closeServer(): Unit = {
    if (closed.compareAndSet(false, true)) {
      participantF.foreach {
        case (indexer, indexServer) =>
          indexer.close()
          indexServer.close()
      }

      for (extraParticipantF <- extraParticipants) {
        extraParticipantF.foreach {
          case (indexer, indexServer) =>
            indexer.close()
            indexServer.close()
        }
      }
      ledger.close()
      materializer.shutdown()
      val _ = system.terminate()
    }
  }

  try {
    Runtime.getRuntime.addShutdownHook(new Thread(() => closeServer()))
  } catch {
    case NonFatal(t) =>
      logger.error("Shutting down Sandbox application because of initialization error", t)
      closeServer()
  }
}
