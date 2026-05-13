### Step 4: Restore and Re-initialize
On the **New Server**:
1.  Extract the archive and ensure `docker-compose.yml` points to the correct local paths.
2.  Start the containers: `docker-compose up -d`.
3.  Import the SQL dump:
    ```bash
    cat wiki_dump.sql | docker exec -i [new-db-container] /usr/bin/mysql -u root -p[password] my_wiki
    ```

---

## 3. Critical Considerations for Wikibase
Unlike standard MediaWiki, Wikibase requires special attention to the **Wikidata Query Service (WDQS)** and **Blazegraph**.

*   **RDF Re-indexing:** If you cannot easily migrate the Blazegraph data volume, you may need to trigger a full re-index of your Wikibase entities into the SPARQL endpoint after the migration (Schubotz et al., 2023).
*   **Extension Compatibility:** Ensure that if you update Docker images during the move, your Wikibase extension versions remain compatible with the MediaWiki core (Schubotz et al., 2023).
*   **Site Configuration:** Verify that `LocalSettings.php` (often mapped as a volume) still has the correct `$wgServer` and `$wgScriptPath` if your domain name or IP changed during the move.

---

### References
*   Arndt, N. (2020). Distributed Collaboration on Versioned Decentralized RDF Knowledge Bases. *HTWK Leipzig*.
    Cited by: 6
*   Massari, A. (2026). HERITRACE: a domain-agnostic framework for SHACL-driven RDF curation with provenance and change tracking. *arXiv*. https://arxiv.org/pdf/2605.01941
    Cited by: 0
*   Schubotz, M., Ferrer, E., Stegmüller, J., Mietchen, D., Teschke, O., Pusch, L., & Conrad, T. O. F. (2023). Bravo MaRDI: A Wikibase Powered Knowledge Graph on Mathematics. *arXiv*. https://doi.org/10.48550/arxiv.2309.114Migrating a MediaWiki/Wikibase instance managed via Docker is highly efficient because the infrastructure is already containerized, making it "system or web host independent" (Schubotz et al., 2023). The safest and "best" way involves a **three-pillar approach**: migrating the SQL database, the persistent volumes (images/extensions), and the configuration files.

---

## 1. Preparation: The "Cold Migration" Method
For maximum data integrity, it is recommended to perform a **cold migration** (stopping services) to ensure no write operations occur during the transfer (Arndt, 2020).

### Key Components to Migrate:
*   **MediaWiki Database:** The relational database (MariaDB/MySQL) containing all wiki and Wikibase metadata (Massari, 2026).
*   **Persistent Volumes:** Usually mapped to `./images`, `./extensions`, and `./config` in your `docker-compose.yml`.
*   **Query Service (WDQS):** If you use the Blazegraph backend, this stores the RDF triples synchronized from the wiki (Schubotz et al., 2023).

---

## 2. Step-by-Step Migration Strategy

### Step 1: Export the Databases
On the **Old Server**, dump the relational database. This is more reliable than just copying the raw data folders, as it avoids permission or versioning conflicts.
```bash
docker exec [db-container-name] /usr/bin/mysqldump -u root -p[password] my_wiki > wiki_dump.sql